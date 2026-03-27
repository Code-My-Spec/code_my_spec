defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  Currently a no-op — the session_id enrichment logic was removed when
  the task lifecycle moved to MCP tools (DraftTask, StartTask, EvaluateTask).
  The hook endpoint remains for future PreToolUse needs.
  """
  use CodeMySpecLocalWeb, :controller

  def handle(conn, _params) do
    json(conn, %{})
  end
end
