defmodule CodeMySpecLocalWeb.Hooks.PostToolUseController do
  @moduledoc """
  Handles the PostToolUse hook.

  HTTP only. The work is `CodeMySpec.Hooks.PostToolUse`'s — recording which
  files this session and agent touched, so the stop hook can scope its block
  decision to them.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.PostToolUse

  def handle(conn, params) do
    {status, body} = PostToolUse.handle(conn.assigns.current_scope, params)
    conn |> put_status(status) |> json(body)
  end
end
