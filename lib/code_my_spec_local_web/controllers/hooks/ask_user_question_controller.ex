defmodule CodeMySpecLocalWeb.Hooks.AskUserQuestionController do
  @moduledoc """
  HTTP layer for the hook. The work is `CodeMySpec.Hooks.AskUserQuestion`'s, so every
  harness answers identically from the same inputs.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Hooks.AskUserQuestion

  def handle(conn, params) do
    {status, body} = AskUserQuestion.handle(conn.assigns[:current_scope], params)
    conn |> put_status(status) |> json(body)
  end
end
