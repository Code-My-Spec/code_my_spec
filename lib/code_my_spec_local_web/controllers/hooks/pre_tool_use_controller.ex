defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  Two responsibilities:
  1. Rewrites `mix test` commands to `mix agent_test` so agents use the
     test fixture infrastructure instead of running tests directly.
  2. Enriches CodeMySpec MCP tool inputs with `session_id` so tools
     don't need the agent to pass it explicitly.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  @mcp_prefix "mcp__plugin_codemyspec_local__"

  def handle(conn, params) do
    tool_name = Map.get(params, "tool_name", "unknown")

    cond do
      String.starts_with?(tool_name, @mcp_prefix) ->
        enrich_mcp_tool(conn, params)

      tool_name == "Bash" ->
        maybe_rewrite_mix_test(conn, params)

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

  defp maybe_rewrite_mix_test(conn, params) do
    command = get_in(params, ["tool_input", "command"]) || ""

    if String.match?(command, ~r/mix test( |$)/) and
         not String.contains?(command, "mix agent_test") do
      replacement = String.replace(command, "mix test", "MIX_ENV=test mix agent_test")

      Logger.info("[PreToolUse] Rewriting: #{String.slice(replacement, 0, 200)}")

      json(conn, %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "allow",
          "permissionDecisionReason" => "Redirected mix test to mix agent_test",
          "updatedInput" => %{"command" => replacement}
        }
      })
    else
      json(conn, %{})
    end
  end
end
