defmodule CodeMySpecLocalWeb.Hooks.SessionStartController do
  @moduledoc """
  Handles the SessionStart hook — finds or creates a session.

  HTTP only. The work is `CodeMySpec.Hooks.SessionStart`'s, which is a database
  operation and therefore the same wherever it runs.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.SessionStart

  # `body_params`, not the action's `params`. Through the router the two agree,
  # but callers reach this directly with the payload only in the body — the
  # tests do — and reading the merged map instead returns 400 for a request
  # that is perfectly well formed.
  def handle(conn, _params) do
    {status, body} = SessionStart.handle(conn.assigns.current_scope, conn.body_params)
    conn |> put_status(status) |> json(body)
  end
end
