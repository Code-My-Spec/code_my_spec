defmodule CodeMySpecLocalWeb.Hooks.NotificationHookController do
  @moduledoc """
  Handles the Notification hook event.

  Forwards notifications to the production server via push, suppressing
  permission-related notifications (handled by the approval hook).
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Notifications.NotificationClient

  def handle(conn, params) do
    notification_type = Map.get(params, "notification_type", "info")
    title = Map.get(params, "title", "Claude Code")
    message = Map.get(params, "message", "")

    if permission_notification?(title, message) do
      Logger.info("[NotificationHook] Suppressing permission notification")
    else
      Task.start(fn ->
        NotificationClient.notify(%{
          type: notification_type,
          title: title,
          body: message
        })
      end)
    end

    json(conn, %{})
  end

  defp permission_notification?(title, message) do
    text = String.downcase("#{title} #{message}")
    String.contains?(text, "permission") or String.contains?(text, "approval")
  end
end
