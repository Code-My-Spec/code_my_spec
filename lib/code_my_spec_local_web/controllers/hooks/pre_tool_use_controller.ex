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
  @test_command ~r/^\s*((?:[A-Z_]+=\S+\s+)*)mix\s+(test|spex)(?:\s+(.*))?$/s

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

  defp maybe_rewrite_test_command(conn, params) do
    command = get_in(params, ["tool_input", "command"]) || ""
    scope = conn.assigns[:current_scope]

    with %{active_project_id: project_id, cwd: cwd} when not is_nil(project_id) and is_binary(cwd) <- scope,
         [_, env_prefix, task | rest] <- Regex.run(@test_command, String.trim(command)),
         true <- Regex.match?(@harmless_env_prefix, env_prefix),
         false <- compound_shell?(rest),
         {:ok, args} <- parse_args(rest) do
      source = if task == "spex", do: "spex", else: "exunit"

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
