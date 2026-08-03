defmodule CodeMySpec.Hooks.NotificationHook do
  @moduledoc """
  The Notification hook.

  Fire-and-forget: it records that the agent said something and always answers
  an empty object, because a notification must never be able to interrupt the
  work it is describing.
  """


  require Logger

  alias CodeMySpec.Notifications.NotificationClient

  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(_scope, params) do
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

    {200, %{}}
  end

  defp permission_notification?(title, message) do
    text = String.downcase("#{title} #{message}")
    String.contains?(text, "permission") or String.contains?(text, "approval")
  end
end
