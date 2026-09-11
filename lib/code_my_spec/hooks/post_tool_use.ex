defmodule CodeMySpec.Hooks.PostToolUse do
  @moduledoc """
  The PostToolUse hook.

  Persists every Write/Edit/MultiEdit/NotebookEdit invocation as a `FileEdit`
  keyed on `(external_session_id, agent_id, file_path)`, so the stop hook can
  scope its block decision to files this session and agent actually touched
  rather than every file dirty on disk — which leaks across parallel sessions.

  `agent_id` is `nil` for main-agent edits and a UUID for Task-spawned
  sub-agent edits.

  Database only: it records *that* a path was written, never reads the file. A
  harness with no database can only forward it.

  So a `file_path` that does not exist is recorded like any other, and that is
  deliberate rather than an oversight — a QA probe asked. The hook records what
  the tool *claimed*; the scanner establishes what is actually on disk. Stat-ing
  the path here would buy nothing and cost correctness: the hook has no working
  copy on the light harness, and a file legitimately written and then moved or
  deleted in the same turn would be dropped from attribution by a check that
  ran a moment too late.

  Nothing downstream is harmed by an over-broad record. Attribution only ever
  *narrows* the stop hook's blocking scope, and a path with no file has no
  problems to match, so a phantom entry scopes nothing in.

  ## Bash commands that rewrite the tree without a Write/Edit

  Also watches for a `Bash` command able to move `HEAD` or rewrite tracked
  files outside Write/Edit — rebase, pull, merge, checkout, reset,
  cherry-pick, stash pop/apply — and stamps `Session.git_rewrite_at`.
  `Validation.narrow_to_attributed/4` reads it: a small mtime-dirty set with
  no recorded edits used to be trusted as "written through something other
  than Write/Edit" (a spex, a direct evaluator). A routine `git fetch && git
  rebase` that pulls in a couple of already-committed files has the identical
  shape and got the same pass, crediting one session with another session's
  already-pushed work (f8af8bf2).
  """

  require Logger

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Hooks.AnalysisAlert
  alias CodeMySpec.Sessions
  alias CodeMySpec.Users.Scope

  @edit_tools ~w(Write Edit MultiEdit NotebookEdit)

  @doc """
  Records the edit and marks the session active.

  Always `{200, %{}}`. Tracking is fire-and-forget by design: a tool call must
  proceed even when persisting the fact of it fails, because the alternative is
  an agent blocked by its own bookkeeping.
  """
  @spec handle(Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    track_edit(params)
    mark_active(scope, params)
    track_git_rewrite(scope, params)

    # The delivery point. Analyzer results used to reach an agent only at its
    # next stop, which is one turn late and free if the agent never stops —
    # see `AnalysisAlert` for the incident that cost a database.
    #
    # Every tool call carries it, not only the ones that write: scoping to edits
    # would reintroduce a "which tools count" judgement, and whichever tool is
    # the exception becomes the blind spot.
    # The agent, not just the session. A Task-spawned subagent shares its
    # parent's session id — this module's own file-edit key says so — so passing
    # the session alone let one silence the other.
    case AnalysisAlert.check(scope, params["session_id"], params["agent_id"]) do
      nil -> {200, %{}}
      alert -> {200, %{"systemMessage" => alert}}
    end
  end

  # Every tool call means this session is doing work: touch its updated_at
  # so the agent-progress view can derive "active" by recency on load (and
  # refresh open pages live). Fire-and-forget.
  defp mark_active(scope, %{"session_id" => session_id} = params) when is_binary(session_id) do
    with %Scope{} = scope <- scope,
         session when not is_nil(session) <- Sessions.get_by_external_id(scope, session_id) do
      Sessions.touch_session(scope, session)
      touch_subagent(scope, session, Map.get(params, "agent_id"))
    else
      _ -> :ok
    end
  end

  defp mark_active(_scope, _params), do: :ok

  # A sub-agent making a tool call is the best evidence of life there is, and
  # until now nothing recorded it: `last_heartbeat_at` was set once at
  # `SubagentStart` and never again, so `Session.active_subagents/2` dropped any
  # sub-agent still working after `subagent_ttl_minutes` — ten by default.
  #
  # That was survivable while the stop hook's exemption keyed on the task row,
  # which never expires. It stopped being survivable when the exemption started
  # asking the registration instead (`a10c035e`): a QA sub-agent running longer
  # than ten minutes would fall off the roster mid-flight and the parent would
  # begin blocking on problems while its sub-agent was demonstrably working —
  # exactly what the exemption exists to prevent. Sub-agents here routinely run
  # far longer than that; one sat in a single browser call for 1800s the day
  # this was written.
  #
  # Here rather than in `track_edit/1` for the reason the comment above
  # `AnalysisAlert.check/3` already gives: scoping to the tools that write
  # reintroduces a "which tools count" judgement, and whichever tool is the
  # exception becomes the blind spot. A sub-agent reading files is alive too.
  #
  # Fire-and-forget like everything else on this path — a tool call must proceed
  # even when the bookkeeping about it fails.
  defp touch_subagent(_scope, _session, nil), do: :ok

  defp touch_subagent(scope, session, agent_id) when is_binary(agent_id) do
    Sessions.touch_subagent(scope, session, agent_id)
    :ok
  end

  defp track_edit(
         %{
           "tool_name" => tool,
           "tool_input" => input,
           "session_id" => session_id
         } = params
       )
       when tool in @edit_tools and is_binary(session_id) do
    agent_id = Map.get(params, "agent_id")

    case extract_file_path(input) do
      {:ok, file_path} ->
        FileEdits.track_edit(session_id, file_path, agent_id)

        Logger.info(
          "[PostToolUse] tracked #{tool} session=#{session_id} agent=#{agent_id || "main"} path=#{file_path}"
        )

      :error ->
        Logger.debug("[PostToolUse] #{tool} fired but no file_path in tool_input")
    end
  end

  defp track_edit(_params), do: :ok

  defp extract_file_path(%{"file_path" => file_path}) when is_binary(file_path),
    do: {:ok, file_path}

  defp extract_file_path(%{"notebook_path" => path}) when is_binary(path), do: {:ok, path}
  defp extract_file_path(_input), do: :error

  # Fire-and-forget, same as the rest of this hook's bookkeeping — recording
  # this must never be the reason a tool call fails.
  @rewrite_subcommands ~w(rebase pull merge checkout reset cherry-pick restore)

  defp track_git_rewrite(scope, %{
         "tool_name" => "Bash",
         "session_id" => session_id,
         "tool_input" => input
       })
       when is_binary(session_id) do
    command = Map.get(input, "command")

    if is_binary(command) and git_rewrite_command?(command) do
      with %Scope{} = scope <- scope,
           session when not is_nil(session) <- Sessions.get_by_external_id(scope, session_id) do
        Sessions.record_git_rewrite(scope, session)
      end
    end

    :ok
  end

  defp track_git_rewrite(_scope, _params), do: :ok

  # A cheap word-boundary check, not a shell parser. Missing an obscure
  # invocation (`git -C dir rebase`) just falls back to today's size-based
  # leniency in `Validation.narrow_to_attributed/4` — the same behavior this
  # is meant to narrow, not a new failure mode. A false positive costs the
  # same: the ambiguous small-and-unattributed case is treated as possibly
  # inherited history rather than possibly a spex's own write.
  defp git_rewrite_command?(command) do
    command
    |> String.split(~r/&&|;|\|/)
    |> Enum.any?(&segment_runs_git_rewrite?/1)
  end

  defp segment_runs_git_rewrite?(segment) do
    segment |> String.split() |> git_rewrite_tokens?()
  end

  defp git_rewrite_tokens?(["git" | rest]) do
    case Enum.drop_while(rest, &String.starts_with?(&1, "-")) do
      ["stash", next | _] -> next in ["pop", "apply"]
      [sub | _] -> sub in @rewrite_subcommands
      [] -> false
    end
  end

  defp git_rewrite_tokens?([_ | rest]), do: git_rewrite_tokens?(rest)
  defp git_rewrite_tokens?([]), do: false
end
