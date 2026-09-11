defmodule CodeMySpecWeb.Live.NotificationsHook do
  @moduledoc """
  LiveView hook that relays the badge topic into the notification dropdown.

  `NotificationLive.Components.Dropdown` (rendered by `Layouts.app/1` on every
  authenticated page) has no process of its own, so it cannot subscribe to
  PubSub and be told when a request is created or resolved somewhere else —
  another tab, another user's action on the same agent. This hook holds that
  subscription on the host LiveView's behalf and pushes a refresh into the
  component with `send_update/2` whenever `{:pending_notifications_changed}`
  fires, halting the message so individual LiveViews never need a matching
  `handle_info` clause of their own.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias CodeMySpec.Notifications
  alias CodeMySpecWeb.NotificationLive.Components.Dropdown

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: user_id}} ->
        if connected?(socket), do: Notifications.subscribe_notifications(user_id)

        {:cont, attach_hook(socket, :notifications_badge, :handle_info, &handle_info/2)}

      _ ->
        {:cont, socket}
    end
  end

  defp handle_info({:pending_notifications_changed}, socket) do
    send_update(Dropdown, id: "notification-dropdown", refresh: make_ref())
    {:halt, socket}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
