defmodule CodeMySpecLocalWeb.Hooks.NotificationHookController do
  @moduledoc """
  HTTP layer for the hook. The work is `CodeMySpec.Hooks.NotificationHook`'s, so every
  harness answers identically from the same inputs.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.NotificationHook

  def handle(conn, params) do
    {status, body} = NotificationHook.handle(conn.assigns[:current_scope], params)
    conn |> put_status(status) |> json(body)
  end
end
