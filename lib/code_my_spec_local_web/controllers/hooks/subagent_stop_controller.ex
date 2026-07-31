defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  HTTP layer for the hook. The work is `CodeMySpec.Hooks.SubagentStop`'s, so every
  harness answers identically from the same inputs.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.SubagentStop

  def handle(conn, params) do
    {status, body} = SubagentStop.handle(conn.assigns[:current_scope], params)
    conn |> put_status(status) |> json(body)
  end
end
