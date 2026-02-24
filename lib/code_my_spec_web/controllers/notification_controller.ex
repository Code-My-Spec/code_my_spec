defmodule CodeMySpecWeb.NotificationController do
  @moduledoc """
  API controller for receiving push notification requests from local servers.

  Protected by OAuth — the local server authenticates via its stored token
  and sends notifications to be dispatched to browser subscribers.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Notifications

  def push(conn, %{"type" => type, "title" => title, "body" => body}) do
    scope = conn.assigns.current_scope

    Notifications.notify_user(scope.user_id, %{
      type: type,
      title: title,
      body: body
    })

    json(conn, %{status: "ok"})
  end

  def push(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required fields: type, title, body"})
  end
end
