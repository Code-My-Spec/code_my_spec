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

  ## Flash relay

  A `LiveComponent`'s own `put_flash/3` is a dead end unless that same
  component also redirects — `Phoenix.LiveView.Channel` only reads a
  component's changed flash back out in the `redirected` branch, so a plain
  `put_flash` from inside `Dropdown` sets an assign nothing ever renders.
  Answering a question from the dropdown has nothing to redirect to (that is
  the entire point), so `Dropdown` instead `send/2`s a `{:notification_flash,
  kind, message}` to its own LiveView process — every stateful component's
  parent, cheaply, since a component always runs inside one — and this hook,
  already attached everywhere `Dropdown` is rendered, is what actually calls
  `put_flash/3` on a socket the render pass will pick up.
  """

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, send_update: 2, put_flash: 3]

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

  defp handle_info({:notification_flash, kind, message}, socket) do
    {:halt, put_flash(socket, kind, message)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
