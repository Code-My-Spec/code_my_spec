defmodule CodeMySpecLocalWeb.Hooks.PostToolUseController do
  @moduledoc """
  Handles the PostToolUse hook.

  Currently a no-op — the agent_id assignment logic was removed when
  the task lifecycle moved to MCP tools (StartTask accepts agent_id directly).
  The hook endpoint remains for future PostToolUse needs.
  """
  use CodeMySpecLocalWeb, :controller

  def handle(conn, _params) do
    json(conn, %{})
  end
end
