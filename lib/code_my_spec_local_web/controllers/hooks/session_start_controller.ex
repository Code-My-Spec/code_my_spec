defmodule CodeMySpecLocalWeb.Hooks.SessionStartController do
  @moduledoc """
  Handles the SessionStart hook — finds or creates a session.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Sessions

  def handle(conn, _params) do
    scope = conn.assigns.current_scope
    session_id = conn.body_params["session_id"]

    if is_nil(session_id) or session_id == "" do
      conn |> put_status(400) |> json(%{error: "session_id is required"})
    else
      case Sessions.find_or_create_session(scope, session_id) do
        {:ok, session} ->
          json(conn, %{session_id: session.id, status: to_string(session.status)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end
  end
end
