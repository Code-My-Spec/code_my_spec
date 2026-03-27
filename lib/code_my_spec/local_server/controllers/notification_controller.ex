defmodule CodeMySpec.LocalServer.Controllers.NotificationController do
  @moduledoc """
  Local server controller for sending push notifications via CLI.
  """

  import Plug.Conn

  alias CodeMySpec.Notifications.NotificationClient

  @doc """
  Send a push notification with arbitrary text.

  ## Request Body

  - `message` - Notification body text (required)
  - `title` - Notification title (optional, defaults to "CodeMySpec")
  - `type` - Notification type (optional, defaults to "info")

  ## Response

  - 200: `{"status": "ok"}`
  - 400: `{"error": "..."}`
  """
  def send_notification(conn) do
    body = conn.body_params

    case Map.get(body, "message") do
      nil ->
        json_response(conn, 400, %{error: "Missing required field: message"})

      message ->
        title = Map.get(body, "title", "CodeMySpec")
        type = Map.get(body, "type", "info")

        Task.start(fn ->
          NotificationClient.notify(%{
            type: type,
            title: title,
            body: message
          })
        end)

        json_response(conn, 200, %{status: "ok"})
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
