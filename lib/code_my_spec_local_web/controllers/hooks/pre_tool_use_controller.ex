defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  Two responsibilities:
  1. Rewrites agent `mix test` / `mix spex` invocations into a curl against
     `/api/analysis/run`, routing them through the shared Analysis service —
     one run record for model- and stop-hook-invoked runs, single-flight
     dedup, Problems reconciled centrally. Only simple invocations in a
     linked project are rewritten; compound shell commands pass through
     untouched (they still run, just unrecorded).
  2. Enriches CodeMySpec MCP tool inputs with `session_id` so tools
     don't need the agent to pass it explicitly.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  @mcp_prefix "mcp__plugin_codemyspec_local__"

  # Claude Code's Bash tool kills commands at ~2 minutes by default — far
  # shorter than a big test suite. The rewritten curl blocks for the whole
  # run, so raise the tool timeout alongside the command.
  @rewrite_timeout_ms 600_000

  def handle(conn, params) do
    tool_name = Map.get(params, "tool_name", "unknown")

    cond do
      String.starts_with?(tool_name, @mcp_prefix) ->
        enrich_mcp_tool(conn, params)

      tool_name == "Bash" ->
        case classify_bash(params) do
          {:deny, reason} -> deny_bash(conn, reason)
          :pass_through -> maybe_rewrite_test_command(conn, params)
        end

      true ->
        json(conn, %{})
    end
  end

  # Inject session_id (and agent_id when available) into MCP tool inputs
  # so tools can resolve the session without the agent passing it explicitly.
  defp enrich_mcp_tool(conn, params) do
    session_id = Map.get(params, "session_id")

    if session_id do
      # Merge session_id and agent_id into existing tool input — don't replace
      agent_id = Map.get(params, "agent_id")
      original_input = Map.get(params, "tool_input", %{})

      merged =
        original_input
        |> Map.put("session_id", session_id)
        |> maybe_put_agent_id(original_input, agent_id)

      Logger.debug("[PreToolUse] Enriching MCP tool with session_id#{if agent_id, do: " + agent_id=#{agent_id}", else: ""}")

      json(conn, %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "allow",
          "permissionDecisionReason" => "Injected session context into MCP tool",
          "updatedInput" => merged
        }
      })
    else
      json(conn, %{})
    end
  end

  defp maybe_put_agent_id(input, original_input, agent_id) do
    cond do
      Map.has_key?(original_input, "agent_id") -> input
      agent_id -> Map.put(input, "agent_id", agent_id)
      true -> input
    end
  end

  # Subagents have no use case for git — QA, codegen, spec-writing all
  # work against the running app and the filesystem, not git history.
  # Block ANY git invocation from a subagent context. Main agent (no
  # agent_id) retains full git access. Issue b5e305fc: a wandering QA
  # subagent ran `git revert` under the engineer's git identity,
  # silently destroying a fix; the tightest safe default is "no git
  # for subagents at all."
  defp classify_bash(params) do
    command = get_in(params, ["tool_input", "command"]) || ""
    agent_id = Map.get(params, "agent_id")

    if is_binary(agent_id) and agent_id != "" and git_command?(command) do
      {:deny,
       "Subagents have no git access. Commits stay with the engineer; propose " <>
         "changes via file edits only. Blocked command: #{String.slice(command, 0, 200)}"}
    else
      :pass_through
    end
  end

  # Match any git invocation (`git ...`) at the start of the command or
  # after a shell separator. Tolerates env-var prefixes and quoting.
  defp git_command?(command) do
    command_norm = String.replace(command, "\n", " ")
    Regex.match?(~r/(^|[;&|`(\s])git(\s|$)/i, command_norm)
  end

  defp deny_bash(conn, reason) do
    Logger.warning("[PreToolUse] Bash denied: #{reason}")

    json(conn, %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => reason
      }
    })
  end

  # Only rewrite a whole, simple invocation — optional env-var prefixes, then
  # `mix test`/`mix spex`, then plain args to end-of-command. Compound shell
  # (cd &&, pipes, subshells) passes through: replacing part of a compound
  # command with a curl would silently change the rest's semantics.
  #
  # That was the intent from the start, but `(.*)` did not implement it: with
  # `/s` it matched to the end of the command, pipes and redirects included, so
  # `mix spex foo_spex.exs --verbose 2>&1 | grep -oE ...` was rewritten with
  # `2>&1`, `|`, `grep`, `-oE`, ... passed to the analysis API *as arguments to
  # mix spex*. The agent got the analyzer's summary instead of the grep output
  # it asked for, and no indication its command had been rewritten.
  #
  # In one run that cost six consecutive retries in four minutes: the agent
  # rephrased the same diagnostic — pipe to grep, redirect to /tmp, redirect to
  # the home dir — because it could not see that a wrapper was eating the
  # pipeline. Excluding shell metacharacters here is what makes the comment
  # above true.
  @test_command ~r/^\s*(?:[A-Z_]+=\S+\s+)*mix\s+(test|spex)(?:\s+([^|&;<>`$()\n]*))?$/

  @doc """
  The rewrite matcher, exposed so the Antigravity hooks controller can share it
  rather than keep a second copy. It kept a copy, and both copies carried the
  same bug.
  """
  @spec test_command_regex() :: Regex.t()
  def test_command_regex, do: @test_command

  defp maybe_rewrite_test_command(conn, params) do
    command = get_in(params, ["tool_input", "command"]) || ""
    scope = conn.assigns[:current_scope]

    with %{active_project_id: project_id, cwd: cwd} when not is_nil(project_id) and is_binary(cwd) <- scope,
         [_, task | rest] <- Regex.run(@test_command, String.trim(command)) do
      source = if task == "spex", do: "spex", else: "exunit"
      args = parse_args(rest)

      replacement = build_curl(conn, cwd, source, args)

      Logger.info("[PreToolUse] Rewriting mix #{task} → analysis API (#{source}, args: #{inspect(args)})")

      json(conn, %{
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
      })
    else
      _ -> json(conn, %{})
    end
  end

  defp parse_args([]), do: []
  defp parse_args([nil]), do: []
  defp parse_args([args_string]), do: OptionParser.split(args_string)

  defp build_curl(conn, cwd, source, args) do
    payload = Jason.encode!(%{source: source, args: args})

    "curl -sS -X POST http://localhost:#{conn.port}/api/analysis/run " <>
      "-H 'Content-Type: application/json' " <>
      "-H 'X-Working-Dir: #{cwd}' " <>
      "--data #{shell_quote(payload)}"
  end

  # Single-quote for sh, escaping embedded single quotes ('\'' dance).
  defp shell_quote(string), do: "'" <> String.replace(string, "'", "'\\''") <> "'"
end
