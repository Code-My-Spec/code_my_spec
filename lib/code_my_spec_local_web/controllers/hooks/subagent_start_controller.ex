defmodule CodeMySpecLocalWeb.Hooks.SubagentStartController do
  @moduledoc """
  HTTP layer for the hook. The work is `CodeMySpec.Hooks.SubagentStart`'s, so every
  harness answers identically from the same inputs.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.SubagentStart

  def handle(conn, params) do
    {status, body} = SubagentStart.handle(conn.assigns[:current_scope], params)
    conn |> put_status(status) |> json(body)
  end
end
