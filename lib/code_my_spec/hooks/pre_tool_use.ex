defmodule CodeMySpec.Hooks.PreToolUse do
  @moduledoc """
  The PreToolUse hook.

  Three jobs, none of which needs a database:

  1. Enrich CodeMySpec MCP tool inputs with `session_id` so tools resolve the
     session without the agent passing it explicitly.
  2. Refuse git from a sub-agent. Commits stay with the engineer.
  3. Route `mix test`/`spex`/`compile`/`credo` through the analysis service.

  Lives here, not in a controller, so every harness decides identically. The
  analysis endpoint is local by nature, so the port is a parameter.
  """

  require Logger

  alias CodeMySpec.Hooks.CommandShape

  # Every MCP server this plugin ships (`mcp__plugin_codemyspec_<server>__*`):
  # the cloud server takes the same `session_id` the local one does.
  @mcp_prefix "mcp__plugin_codemyspec_"

  # Claude Code's Bash tool kills commands at ~2 minutes by default — far
  # shorter than a big test suite. The rewritten curl blocks for the whole
  # run, so raise the tool timeout alongside the command.
  @rewrite_timeout_ms 600_000

  # git subcommands a subagent may run: none can write a ref, an object, the
  # index, or the working tree.
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
  `/api/harnesses/<id>/…`. See knowledge/analysis, "Routing analysis commands".
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

  # Subagents may read git history but not change it; the main agent (no
  # agent_id) gets everything.
  # See knowledge/analysis, "Subagent git".
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

  # A whole, simple invocation: optional env-var prefixes, one of the four
  # analyzers, plain args to end-of-command.
  @test_command ~r/^\s*((?:[A-Z_]+=\S+\s+)*)mix\s+(test|spex|compile|credo)(?:\s+(.*))?$/s

  # `(.*)` with `/s` swallows any shell after the mix invocation; a match on
  # these refuses the rewrite rather than dropping a redirect or a pipe.
  @shell_metachars ~r/[;&|<>`$\n(){}]/

  # The curl carries no environment. `MIX_ENV=test` is the default and means
  # nothing; any other prefix changes what runs, so it refuses the rewrite.
  @harmless_env_prefix ~r/^(?:MIX_ENV=test\s+)*$/

  @doc """
  Whether a shell command is a whole, simple `mix test`/`spex`/`compile`/`credo`
  invocation worth routing through the analysis service.

  `{:ok, task, source, args}` when it is; `:skip` when the command carries
  shell the rewrite would swallow, an env-var prefix the curl would drop, or
  quoting that cannot be split unambiguously.
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

  # Only the test segment of a compound command is routed (`CommandShape`):
  # `MIX_ENV=test mix test x 2>&1 | tail -20` keeps its redirect and pipe. A
  # segment after `cd` routes when the directory is inside this copy; a `cd`
  # anywhere else may be another copy, and passes through. `mix compile`/`credo`
  # still route only as a whole command.
  defp maybe_rewrite_test_command(scope, params, port, served_by) do
    command = get_in(params, ["tool_input", "command"]) || ""
    root = Map.get(scope || %{}, :cwd) || Map.get(params, "cwd")

    with %{active_project_id: project_id} when not is_nil(project_id) <- scope,
         nil <- nested_checkout(params, command),
         {:ok, endpoint} <- analysis_endpoint(scope, served_by) do
      case route_command(command, root, port, endpoint) do
        {:routed, replacement, what} -> rewrite(replacement, what)
        :pass -> rewrite_whole(command, port, endpoint)
      end
    else
      :nested -> %{}
      _ -> no_rewrite(scope, command)
    end
  end

  # A subagent's worktree is another tree; the copy's harness would run the test
  # in the copy, so it is not routed.
  defp nested_checkout(%{"nested_checkout" => dir}, command) when is_binary(dir) do
    if CommandShape.test?(command), do: log_decision("not routed", [:nested_checkout], [])
    :nested
  end

  defp nested_checkout(_params, _command), do: nil

  @doc """
  `command` with its mix test/spex segments routed through the analysis service
  for the copy at `root`, or `:pass`. Every test decision is logged with the
  command's shape. The PreToolUse hook and an in-app agent's own bash tool
  (`CmsHarness.Agents.Tools.Bash`) both route through this.
  """
  @spec route_command(
          String.t(),
          String.t() | nil,
          pos_integer(),
          {:local | :harness, String.t()}
        ) ::
          {:routed, String.t(), String.t()} | :pass
  def route_command(command, root, port, endpoint) do
    case CommandShape.route(command, &route_segment(&1, root, port, endpoint)) do
      {:routed, replacement, classes, mixes} ->
        log_decision("routed", classes, mixes)
        {:routed, replacement, Enum.map_join(mixes, ", ", &"mix #{&1.task}")}

      {:pass, classes} ->
        if CommandShape.test?(command), do: log_decision("not routed", classes, [])
        :pass
    end
  end

  @doc "How long a routed run may take: a suite, not a shell one-liner."
  def rewrite_timeout_ms, do: @rewrite_timeout_ms

  defp route_segment(%{cd: cd, source: source, args: args}, root, port, endpoint) do
    if (cd == nil or inside?(cd, root)) and not expands?(args),
      do: {:ok, build_curl(port, endpoint, source, args)},
      else: :pass
  end

  # The shell expands `$f` and backticks; the curl's JSON would carry them as
  # written, and a run of the file `$f` finds nothing and answers green.
  defp expands?(args), do: Enum.any?(args, &String.contains?(&1, ["$", "`"]))

  # Paths only: the server deciding for a proxied copy cannot see its disk. A
  # relative `cd` is taken from the session's directory, which is in the copy.
  defp inside?(:unknown, _root), do: false
  defp inside?(_cd, root) when not is_binary(root), do: false

  defp inside?(cd, root) do
    root = Path.expand(root)
    dir = Path.expand(cd, root)
    dir == root or String.starts_with?(dir, root <> "/")
  end

  defp rewrite_whole(command, port, endpoint) do
    case classify_test_command(command) do
      {:ok, task, source, args} when task in ["compile", "credo"] ->
        rewrite(build_curl(port, endpoint, source, args), "mix #{task}")

      _ ->
        %{}
    end
  end

  # Every mix test/spex decision, with the command's shape, so a shape that is
  # never routed shows up as one rather than as silence.
  defp log_decision(decision, classes, mixes) do
    Logger.info(
      "[PreToolUse] mix test/spex #{decision} (shape: #{Enum.join(classes, ", ")})" <>
        Enum.map_join(mixes, "", &" #{&1.source} #{inspect(&1.args)}")
    )
  end

  defp rewrite(replacement, what) do
    %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "allow",
        "permissionDecisionReason" =>
          "Routed #{what} through the CodeMySpec analysis service (shared run record, single-flight)",
        "updatedInput" => %{
          "command" => replacement,
          "timeout" => @rewrite_timeout_ms
        }
      }
    }
  end

  # A test command the scope cannot route (no project, or no working copy id)
  # warns by name: the same `%{}` as "not a test command" would hide a feature
  # being off.
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

  # True when the arg tail carries shell the rewrite would swallow. A real
  # `mix test` arg never needs these characters.
  defp compound_shell?([]), do: false
  defp compound_shell?([nil]), do: false
  defp compound_shell?([args_string]), do: Regex.match?(@shell_metachars, args_string)

  defp parse_args([]), do: {:ok, []}
  defp parse_args([nil]), do: {:ok, []}

  defp parse_args([args_string]) do
    {:ok, OptionParser.split(args_string)}
  rescue
    # Unbalanced quotes: `[]` would silently widen a targeted run to the whole
    # suite, so refuse the rewrite and let the original command run.
    _ -> :error
  end

  # The router comes from the caller (`served_by`); the working copy id
  # identifies the copy to it. No path goes on the wire.
  defp analysis_endpoint(%{active_working_copy_id: id}, served_by)
       when is_binary(id) and served_by in [:local, :harness],
       do: {:ok, {served_by, id}}

  defp analysis_endpoint(_scope, _served_by), do: :error

  # One plain `curl`, no `sh -c` (Claude Code's guard cannot read inside a `-c`
  # script, so auto mode refuses it). A failing run answers 422 with the tool's
  # output; `--fail-with-body` prints it and exits nonzero, like `mix test`.
  defp build_curl(port, endpoint, source, args) do
    payload = Jason.encode!(%{source: source, args: args})
    url = "http://localhost:#{port}#{path(endpoint)}"

    "curl -sS --fail-with-body -X POST '#{url}' -H 'Content-Type: application/json' " <>
      header(endpoint) <> "--data #{shell_quote(payload)}"
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
