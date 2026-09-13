defmodule CodeMySpecLocalWeb.Hooks.PreToolUseController do
  @moduledoc """
  Handles the PreToolUse hook.

  HTTP only. The decision — MCP session enrichment, refusing git from a
  sub-agent, and routing `mix test`/`mix spex` through the analysis service —
  is `CodeMySpec.Hooks.PreToolUse`'s, so every harness applies the same rule
  rather than keeping a copy of it.

  The port is passed through because the analysis endpoint the rewrite points
  at is served by whichever harness handled this request — and `:local` beside
  it, because this router is the one that answers there: a bare
  `/api/analysis/run` taking `X-Harness-Id`. `cms_harness` addresses the same
  work as `/api/harnesses/<id>/analysis/run`, and the two are not
  interchangeable. Stating it here rather than letting `PreToolUse` infer it is
  what fixed 60b50e40, where the inference sent every proxied copy at this
  router's route and the agent got a 404 instead of a test run.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.PreToolUse

  def handle(conn, params) do
    json(conn, PreToolUse.decide(conn.assigns[:current_scope], params, conn.port, :local))
  end
end
