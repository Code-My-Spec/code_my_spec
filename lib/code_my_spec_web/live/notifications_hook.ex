defmodule CodeMySpecWeb.Live.NotificationsHook do
  @moduledoc """
  LiveView hook that keeps `@pending_notifications` (the navbar badge count)
  assigned and live on every authenticated LiveView.

  Subscribes to the user's badge topic and halts `{:pending_notifications_changed}`
  so individual LiveViews never need a matching `handle_info` clause. The inbox
  list refresh uses a separate topic (`subscribe_notifications_list/1`) that this
  hook passes through.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias CodeMySpec.Notifications

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: user_id}} ->
        if connected?(socket), do: Notifications.subscribe_notifications(user_id)

        socket =
          socket
          |> assign(:pending_notifications, Notifications.count_pending_notifications(user_id))
          |> attach_hook(:notifications_badge, :handle_info, &handle_info/2)

        {:cont, socket}

      _ ->
        {:cont, assign(socket, :pending_notifications, 0)}
    end
  end

  defp handle_info({:pending_notifications_changed}, socket) do
    user_id = socket.assigns.current_scope.user.id
    {:halt, assign(socket, :pending_notifications, Notifications.count_pending_notifications(user_id))}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
