defmodule CodeMySpec.Hooks.PreToolUse do
  @moduledoc """
  The PreToolUse hook.

  Three jobs, none of which needs a database:

  1. Enrich CodeMySpec MCP tool inputs with `session_id` so tools resolve the
     session without the agent passing it explicitly.
  2. Refuse git from a sub-agent. Commits stay with the engineer.
  3. Route a whole, simple `mix test`/`spex`/`compile`/`credo` through the
     analysis service.

  Lives here rather than in a controller because this rule has already been
  duplicated once — the Antigravity hooks controller kept its own copy of the
  matcher, the pipe-swallowing bug had to be found twice, and only got fixed
  once. A third harness would have been a third copy.

  The analysis endpoint the rewrite points at is local by nature, so the port
  is a parameter rather than something this module assumes.
  """

  require Logger

  # Every MCP server this plugin ships, not just the local one. The tools are
  # named `mcp__plugin_codemyspec_<server>__*`, and the cloud server
  # (`cms_cloud`) takes the same `session_id` the local one does — matching
  # only `local` meant its task tools got none, and dead-ended on a hook that
  # had the id in hand and was declining to pass it on.
  @mcp_prefix "mcp__plugin_codemyspec_"

  # Claude Code's Bash tool kills commands at ~2 minutes by default — far
  # shorter than a big test suite. The rewritten curl blocks for the whole
  # run, so raise the tool timeout alongside the command.
  @rewrite_timeout_ms 600_000

  # git subcommands a subagent may run. Every one of these only reads: none can
  # write a ref, an object, the index, or the working tree. That is the whole
  # criterion — see `classify_bash/1` for why the line is drawn at mutation
  # rather than at git.
  @read_only_git ~w(log show diff status blame rev-parse describe shortlog whatchanged)

  @doc """
  The hook's response for a tool about to run.

  `port` is where the rewritten analysis curl should point — the harness that
  will actually serve it, since the analysis endpoint is local by nature. An
  empty map means "no opinion, proceed".

  `served_by` says *which router* answers on that port, and it is the caller's
  to state rather than this module's to infer. `:local` is the packaged
  `cms server`, which takes a bare `/api/analysis/run` and an `X-Harness-Id`
  header; `:harness` is `cms_harness`, where every route is addressed
  `/api/harnesses/<id>/…`.

  It used to be guessed from whether the scope carried a `cwd`, and the guess was
  wrong for every proxied working copy: a decision made on the cloud server and
  returned down the channel carries a `cwd` (it describes the agent's disk) and
  is destined for a harness (which has no bare route). So `mix test` and
  `mix spex` rewrote to a URL that 404s, and the agent's command never ran at
  all — the failure it saw was the hook's, in the hook's voice, for a command it
  had asked to run itself. Reported live by another session and reproduced here
  against :4004: bare route 404, id-addressed route serves. Issue `60b50e40`.

  The two callers each know the answer with certainty and neither has to look at
  a scope to find it.
  """
  @spec decide(CodeMySpec.Users.Scope.t() | nil, map(), pos_integer(), :local | :harness) :: map()
  def decide(scope, params, port, served_by) do
    tool_name = Map.get(params, "tool_name", "unknown")

    cond do
      String.starts_with?(tool_name, @mcp_prefix) ->
        enrich_mcp_tool(params)

      tool_name == "Bash" ->
        case classify_bash(params) do
          {:deny, reason} -> deny_bash(reason)
          :pass_through -> maybe_rewrite_test_command(scope, params, port, served_by)
        end

      true ->
        %{}
    end
  end

  # Inject session_id (and agent_id when available) into MCP tool inputs
  # so tools can resolve the session without the agent passing it explicitly.
  defp enrich_mcp_tool(params) do
    session_id = Map.get(params, "session_id")

    if session_id do
      # Merge session_id and agent_id into existing tool input — don't replace
      agent_id = Map.get(params, "agent_id")
      original_input = Map.get(params, "tool_input", %{})

      merged =
        original_input
        |> Map.put("session_id", session_id)
        |> maybe_put_agent_id(original_input, agent_id)

      Logger.debug(
        "[PreToolUse] Enriching MCP tool with session_id#{if agent_id, do: " + agent_id=#{agent_id}", else: ""}"
      )

      %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "allow",
          "permissionDecisionReason" => "Injected session context into MCP tool",
          "updatedInput" => merged
        }
      }
    else
      %{}
    end
  end

  defp maybe_put_agent_id(input, original_input, agent_id) do
    cond do
      Map.has_key?(original_input, "agent_id") -> input
      agent_id -> Map.put(input, "agent_id", agent_id)
      true -> input
    end
  end

  # Subagents may read git history but not change it. Issue b5e305fc: a
  # wandering QA subagent ran `git revert` under the engineer's git identity,
  # silently destroying a fix, and the response was "no git for subagents at
  # all" — the tightest safe default at the time.
  #
  # Too tight, as it turned out. `66f3b098`: the stop hook, when it cannot
  # attribute findings, tells the agent to "check `git log -1 -- <path>` before
  # repairing anything you do not recognise" — and this denied it. So the
  # harness named the one diagnostic that would clear the block and refused it
  # in the same breath, leaving subagents in a loop with no honest exit:
  # `clear_problems` would record a falsehood, and fixing another area's spex
  # was out of scope. An agent that had finished its assignment could not stop.
  #
  # b5e305fc's danger is mutation, and `log`/`show`/`diff`/`blame` cannot
  # mutate. So the allowlist is by subcommand rather than by tool.
  #
  # Main agent (no agent_id) still gets everything.
  defp classify_bash(params) do
    command = get_in(params, ["tool_input", "command"]) || ""
    agent_id = Map.get(params, "agent_id")

    classify_for_agent(subagent?(agent_id), command)
  end

  defp subagent?(agent_id), do: is_binary(agent_id) and agent_id != ""

  defp classify_for_agent(false, _command), do: :pass_through

  defp classify_for_agent(true, command) do
    decide_git(git_command?(command), git_subcommands(command), command)
  end

  defp decide_git(false, _subcommands, _command), do: :pass_through

  # git is in there but nothing parsed as a subcommand — a bare `git`, or a
  # shape this does not understand. Deny: an allowlist that passes what it
  # cannot read is not an allowlist.
  defp decide_git(true, [], command), do: {:deny, git_denial(command)}

  # Every invocation must be read-only, not just one of them. `git log && git
  # push` contains a read-only call and is still a push.
  defp decide_git(true, subcommands, command) do
    allow_read_only(Enum.all?(subcommands, &(&1 in @read_only_git)), command)
  end

  defp allow_read_only(true, _command), do: :pass_through
  defp allow_read_only(false, command), do: {:deny, git_denial(command)}

  defp git_denial(command) do
    "Subagents may read git history but not change it — #{Enum.join(@read_only_git, ", ")} " <>
      "are allowed. Commits stay with the engineer; propose changes via file edits only. " <>
      "Blocked command: #{String.slice(command, 0, 200)}"
  end

  # Match any git invocation (`git ...`) at the start of the command or
  # after a shell separator. Tolerates env-var prefixes and quoting.
  defp git_command?(command) do
    command_norm = String.replace(command, "\n", " ")
    Regex.match?(~r/(^|[;&|`(\s])git(\s|$)/i, command_norm)
  end

  # The subcommand of every git invocation in the command, in order.
  defp git_subcommands(command) do
    command
    |> String.replace("\n", " ")
    |> then(&Regex.scan(~r/(?:^|[;&|`(\s])git\s+([^;&|`()]*)/i, &1))
    |> Enum.map(&subcommand_of/1)
    |> Enum.reject(&is_nil/1)
  end

  defp subcommand_of([_full, args]) do
    args |> String.split(~r/\s+/, trim: true) |> take_subcommand()
  end

  defp subcommand_of(_match), do: nil

  # Skip git's global options so `git -C path log` and `git --no-pager log` both
  # read as `log`. `-C` and `-c` take a value; the rest do not.
  defp take_subcommand(["-C", _path | rest]), do: take_subcommand(rest)
  defp take_subcommand(["-c", _config | rest]), do: take_subcommand(rest)
  defp take_subcommand(["--no-pager" | rest]), do: take_subcommand(rest)
  defp take_subcommand(["-P" | rest]), do: take_subcommand(rest)
  defp take_subcommand(["--git-dir=" <> _rest_of_flag | rest]), do: take_subcommand(rest)
  defp take_subcommand(["--work-tree=" <> _rest_of_flag | rest]), do: take_subcommand(rest)
  defp take_subcommand([subcommand | _rest]), do: subcommand
  defp take_subcommand([]), do: nil

  defp deny_bash(reason) do
    Logger.warning("[PreToolUse] Bash denied: #{reason}")

    %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => reason
      }
    }
  end

  # Only rewrite a whole, simple invocation — optional env-var prefixes, then
  # one of the four analyzers, then plain args to end-of-command. Compound
  # shell (cd &&, pipes, subshells) passes through: replacing part of a
  # compound command with a curl would silently change the rest's semantics.
  #
  # All four rather than just test/spex — `compiler` and `credo` get the same
  # single-flight ledger, the same machine-wide slot, and the same duplicate
  # coalescing as the other two. The analysis service already treated all
  # four as equally valid sources (`@valid_sources` on both controllers); this
  # was the one place that still only asked for two of them. John: "Same
  # treatment to all analyzers."
  @test_command ~r/^\s*((?:[A-Z_]+=\S+\s+)*)mix\s+(test|spex|compile|credo)(?:\s+(.*))?$/s

  # `(.*)` with `/s` swallows everything to end of command, including shell
  # that follows the mix invocation — so the "compound shell passes through"
  # promise above was never enforced. `mix spex foo.exs > out.txt 2>&1; tail
  # out.txt` matched, and the rewrite dropped the redirect and the tail while
  # storing `[">", "out.txt", "2>&1;", "tail", ...]` as the run's args. Two
  # harms, both silent: the agent's requested output never materialised, and
  # the junk tokens were persisted as if they were paths. Issue 0b54e827.
  @shell_metachars ~r/[;&|<>`$\n(){}]/

  # The curl carries no environment, so any env-var prefix the agent wrote is
  # dropped by the rewrite. `MIX_ENV=test` is the default for both tasks and
  # so means nothing; anything else (`MIX_ENV=cli_dev`, a feature flag) changes
  # what runs, and dropping it silently is the same class of bug as swallowing
  # a redirect.
  @harmless_env_prefix ~r/^(?:MIX_ENV=test\s+)*$/

  @doc """
  Whether a shell command is a whole, simple `mix test`/`spex`/`compile`/`credo`
  invocation worth routing through the analysis service.

  `{:ok, task, source, args}` when it is; `:skip` when the command carries
  shell the rewrite would swallow, an env-var prefix the curl would drop, or
  quoting that cannot be split unambiguously.

  Public because the Antigravity hooks controller makes the same decision
  against a different tool payload. It used to make it with its own copy of the
  regex and its own `parse_args`, and when this rule was fixed here that copy
  kept the bug — so the rule lives in one place now.
  """
  @spec classify_test_command(String.t()) ::
          {:ok, String.t(), String.t(), [String.t()]} | :skip
  def classify_test_command(command) when is_binary(command) do
    with [_, env_prefix, task | rest] <- Regex.run(@test_command, String.trim(command)),
         true <- Regex.match?(@harmless_env_prefix, env_prefix),
         false <- compound_shell?(rest),
         {:ok, args} <- parse_args(rest) do
      {:ok, task, source_for(task), args}
    else
      _ -> :skip
    end
  end

  defp source_for("spex"), do: "spex"
  defp source_for("compile"), do: "compiler"
  defp source_for("credo"), do: "credo"
  defp source_for("test"), do: "exunit"

  defp maybe_rewrite_test_command(scope, params, port, served_by) do
    command = get_in(params, ["tool_input", "command"]) || ""

    with %{active_project_id: project_id} when not is_nil(project_id) <- scope,
         {:ok, endpoint} <- analysis_endpoint(scope, served_by),
         {:ok, task, source, args} <- classify_test_command(command) do
      replacement = build_curl(port, endpoint, source, args)

      Logger.info(
        "[PreToolUse] Rewriting mix #{task} → analysis API (#{source}, args: #{inspect(args)})"
      )

      %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "allow",
          "permissionDecisionReason" =>
            "Routed mix #{task} through the CodeMySpec analysis service (shared run record, single-flight)",
          "updatedInput" => %{
            "command" => replacement,
            "timeout" => @rewrite_timeout_ms
          }
        }
      }
    else
      _ -> no_rewrite(scope, command)
    end
  end

  # `%{}` means "no opinion", and it was the answer to two different questions:
  # this is not a test command, and this *is* one but the scope could not carry
  # the rewrite. The second is a feature being off, and it looked exactly like
  # the feature being irrelevant.
  #
  # It used to be off on the light harness, and this is where that was found.
  # The rewrite required `cwd`, which that scope has no business setting, so
  # every `mix test` an agent ran went straight to the shell unrecorded and the
  # stop hook re-ran the whole suite afterwards. It now addresses the harness by
  # id instead — see `analysis_endpoint/1`.
  #
  # What remains here is a scope carrying neither: no project, or a project with
  # no way to say which working copy. That is still a feature being off, and it
  # still says so by name rather than by returning the same `%{}` that means
  # "not a test command".
  defp no_rewrite(scope, command) do
    case classify_test_command(command) do
      {:ok, task, _source, _args} ->
        Logger.warning(
          "[PreToolUse] not rewriting `mix #{task}`: " <>
            "project_id=#{inspect(scope && scope.active_project_id)} " <>
            "harness=#{inspect(scope && scope.active_working_copy_id)} " <>
            "cwd=#{inspect(scope && scope.cwd)}. The run will not be recorded."
        )

      _ ->
        :ok
    end

    %{}
  end

  # True when the arg tail carries shell that the rewrite would swallow.
  # Redirections, separators, substitutions, subshells — anything whose
  # meaning is the shell's rather than mix's. A legitimate `mix test` arg is a
  # path, a `--flag`, or a flag value; none of them need these characters, so
  # rejecting is cheap and the cost of a false negative is a silently altered
  # command.
  defp compound_shell?([]), do: false
  defp compound_shell?([nil]), do: false
  defp compound_shell?([args_string]), do: Regex.match?(@shell_metachars, args_string)

  defp parse_args([]), do: {:ok, []}
  defp parse_args([nil]), do: {:ok, []}

  defp parse_args([args_string]) do
    {:ok, OptionParser.split(args_string)}
  rescue
    # Unbalanced quotes make the split ambiguous, and the shell would resolve
    # it differently than we would. Returning `[]` here would read as "no
    # args" and silently widen a targeted run to the whole suite, so refuse
    # the rewrite and let the original command run.
    _ -> :error
  end

  # Which working copy the run is about, and how that is said.
  #
  # **`cwd` is checked first and the order is the whole correctness argument.**
  # A heavy harness carries *both*: `HarnessScope` resolves the id and then
  # builds a scope with a `cwd` on it. Matching the id first would have pointed
  # it at the light harness's id-addressed route, which the heavy harness's own
  # router does not serve — a 404 on every `mix test` an agent runs against it.
  #
  # The real question is "can whoever answers this reach the disk", and `cwd` is
  # what answers it. A light harness has none and must not be given one: `cwd`
  # means a directory *this* process can read, and `Knowledge`, `ProjectSync` and
  # the hex-doc projector all take it at its word. On a diskless server that is a
  # path to another machine; on a developer box where both are the same machine
  # it would read a real tree, the wrong one, convincingly.
  #
  # So `cwd` picks the endpoint and the id is what identifies the working copy to
  # it. Those used to be the same answer — the heavy route took an
  # `X-Working-Dir` header — and separating them is the point: a path on the wire
  # is a filesystem location supplied by the caller, which the server then writes
  # to, and a wrong one succeeds against the wrong disk rather than failing.
  defp analysis_endpoint(%{active_working_copy_id: id}, served_by)
       when is_binary(id) and served_by in [:local, :harness],
       do: {:ok, {served_by, id}}

  defp analysis_endpoint(_scope, _served_by), do: :error

  # A bare `curl` can't hand back the analyzer's own pass/fail as its own exit
  # code — curl exits 0 for any HTTP request it completed, tests failed or
  # not. That is why the response used to carry a footer line spelling out
  # the exit status in the body: nothing else was reading it. It also meant
  # `mix test` never looked like `mix test` again — the whole point of
  # routing it was to be invisible, and a footer the agent had never seen
  # from a real test run was the opposite of that.
  #
  # So the two are split at the transport instead of glued into the body:
  # `-o`/`-w` send the response body to a file and the HTTP status to stdout
  # on their own, the endpoint answers 200 for a clean run and something
  # else for anything short of it (see both `AnalysisController`s), and this
  # script re-emits the body untouched and exits 0 or 1 to match — the same
  # two numbers a real `mix test`/`mix spex` would have given back.
  defp build_curl(port, endpoint, source, args) do
    payload = Jason.encode!(%{source: source, args: args})
    url = "http://localhost:#{port}#{path(endpoint)}"

    script =
      "t=$(mktemp); c=$(curl -sS -o \"$t\" -w '%{http_code}' -X POST '#{url}' " <>
        "-H 'Content-Type: application/json' " <>
        header(endpoint) <>
        "--data #{shell_quote(payload)}); cat \"$t\"; rm -f \"$t\"; [ \"$c\" = 200 ]"

    "sh -c " <> shell_quote(script)
  end

  defp path({:harness, id}), do: "/api/harnesses/#{id}/analysis/run"
  defp path({:local, _id}), do: "/api/analysis/run"

  # The id-addressed route carries it in the path already; repeating it in a
  # header would be two places to disagree.
  defp header({:harness, _id}), do: ""
  defp header({:local, id}), do: "-H 'X-Harness-Id: #{id}' "

  # Single-quote for sh, escaping embedded single quotes ('\'' dance).
  defp shell_quote(string), do: "'" <> String.replace(string, "'", "'\\''") <> "'"
end
