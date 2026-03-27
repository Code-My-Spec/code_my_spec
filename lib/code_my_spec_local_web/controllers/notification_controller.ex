defmodule CodeMySpecLocalWeb.NotificationController do
  @moduledoc """
  Send push notifications via the production server.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Notifications.NotificationClient

  def send_notification(conn, params) do
    case Map.get(params, "message") do
      nil ->
        conn |> put_status(400) |> json(%{error: "Missing required field: message"})

      message ->
        title = Map.get(params, "title", "CodeMySpec")
        type = Map.get(params, "type", "info")

        Task.start(fn ->
          NotificationClient.notify(%{type: type, title: title, body: message})
        end)

        json(conn, %{status: "ok"})
    end
  end
end
