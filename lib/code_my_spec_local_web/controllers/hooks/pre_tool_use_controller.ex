defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  Rewrites `mix test` commands to `mix agent_test` so agents use the
  test fixture infrastructure instead of running tests directly.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  def handle(conn, params) do
    tool_name = Map.get(params, "tool_name", "unknown")
    command = get_in(params, ["tool_input", "command"]) || ""

    if tool_name == "Bash" and String.match?(command, ~r/mix test( |$)/) and
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
