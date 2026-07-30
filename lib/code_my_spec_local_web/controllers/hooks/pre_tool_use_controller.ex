defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  HTTP only. The decision — MCP session enrichment, refusing git from a
  sub-agent, and routing `mix test`/`mix spex` through the analysis service —
  is `CodeMySpec.Hooks.PreToolUse`'s, so every harness applies the same rule
  rather than keeping a copy of it.

  The port is passed through because the analysis endpoint the rewrite points
  at is served by whichever harness handled this request.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.PreToolUse

  def handle(conn, params) do
    json(conn, PreToolUse.decide(conn.assigns[:current_scope], params, conn.port))
  end
end
