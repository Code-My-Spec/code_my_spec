defmodule CodeMySpec.Hooks.PostToolUse do
  @moduledoc """
  The PostToolUse hook.

  Persists every Write/Edit/MultiEdit/NotebookEdit invocation as a `FileEdit`
  keyed on `(external_session_id, agent_id, file_path)`, so a stop knows which
  files this session and agent actually touched rather than every file dirty on
  disk — which leaks across parallel sessions.

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

  Nothing downstream is harmed by an over-broad record: a path with no file
  matches nothing.

  ## Bash commands that rewrite the tree without a Write/Edit

  Also watches for a `Bash` command able to move `HEAD` or rewrite tracked
  files outside Write/Edit — rebase, pull, merge, checkout, reset,
  cherry-pick, stash pop/apply — and stamps the terminal agent's `git_rewrite_at`.
  `Validation.narrow_to_attributed/4` reads it: a small mtime-dirty set with
  no recorded edits used to be trusted as "written through something other
  than Write/Edit" (a spex, a direct evaluator). A routine `git fetch && git
  rebase` that pulls in a couple of already-committed files has the identical
  shape and got the same pass, crediting one session with another session's
  already-pushed work (f8af8bf2).
  """

  require Logger

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  @edit_tools ~w(Write Edit MultiEdit NotebookEdit)

  @doc """
  Records the edit.

  Always `{200, %{}}`. Tracking is fire-and-forget by design: a tool call must
  proceed even when persisting the fact of it fails, because the alternative is
  an agent blocked by its own bookkeeping.
  """
  @spec handle(Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    track_edit(params)
    track_git_rewrite(scope, params)

    # No annotation: problems are information that gates at promotion, and a
    # line on every tool call was a nudge (John, 2026-10-18).
    {200, %{}}
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
      with %Scope{} = scope <- scope do
        Agents.record_git_rewrite(scope, session_id)
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
