defmodule CodeMySpecWeb.NotificationLive.Components.Dropdown do
  @moduledoc """
  The bell, its badge, and the pending items themselves — in one place.

  Dealing with a notification used to mean leaving whatever page you were on:
  the bell only ever navigated to `/app/notifications`, a full page, and
  acting on an item there navigated again, to `/app/questions/:id` or
  `/app/permissions/:id`. Answering one thing cost two round trips away from
  the work it interrupted. This renders both the trigger and the pending
  items inline, in a dropdown, wherever the bell already was — reusing the
  same components (`ChatComponents.question/1`, `PermissionComponents.permission_request/1`)
  the standalone pages render, the same way an agent's own conversation
  already does.

  ## Why this calls the `Notifications` context directly

  `AccountLive.Components.MembersList` and `InvitationsLive.Components.PendingInvitations`
  — the other stateful `LiveComponent`s in this app — never call a context
  function themselves; they `send(self(), ...)` up to the one specific parent
  LiveView that owns the mutation. That does not transfer here: this
  component's "parent" is `Layouts.app/1`, rendered from roughly thirty
  different LiveView modules, so pushing the mutation up would mean every one
  of them handling `{:answer_question, ...}` — recreating, per page, the exact
  boilerplate this component exists to remove. Calling
  `Notifications.answer_question_request/2` / `resolve_permission_request/2`
  directly here mirrors what `QuestionLive.Show` / `PermissionLive.Show`
  already do; it is a page in every sense but the URL.

  ## Why `send_update`, not a subscription

  A `LiveComponent` has no process of its own — no `handle_info/2` — so it
  cannot subscribe to PubSub and be told when a request is created or
  resolved *somewhere else* (another tab, another user's action on the same
  agent). `NotificationsHook`, already mounted on essentially every
  authenticated page, holds that subscription and relays it here via
  `send_update/2` whenever the existing `{:pending_notifications_changed}`
  broadcast fires. This is the only `send_update` call in the codebase today,
  for the reason above: it is the only component whose refresh cannot come
  from its own parent's next render.

  ## Why a resolved item is never removed

  The panel opens via a plain daisyUI `dropdown`/`dropdown-content` pair —
  `:focus-within`, no JS, no server round trip to open it. If resolving an
  item removed its node from the list, the button the user just clicked would
  vanish from the DOM, focus would revert to nothing, `:focus-within` would go
  false, and the *entire panel* would snap shut — including hiding every
  other request still pending. `ChatComponents.question/1` already avoids
  this (the card stays mounted; only its internal branch changes); the same
  has to hold here, so an item is only ever dropped from `@pending` by a full
  reload (`send_update`, or the next mount), never by the event that resolved it.
  """
  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpecWeb.ChatComponents
  alias CodeMySpecWeb.PermissionComponents

  # Rendered on every authenticated page's initial load, not just the inbox —
  # this table has had runaway rows before (224 pending tap-out requests
  # behind ten agents, one holding 129), so the panel caps what it draws
  # rather than trusting "pending" to stay small. The badge still reports the
  # true total.
  @limit 20

  # A `send_update`-driven reload. Keyed off a distinct message shape rather
  # than a plain `update/2` fallthrough so a normal parent re-render (which
  # passes `current_scope` again on every single page navigation) does not
  # also requery the database — only an actual broadcast does.
  def update(%{refresh: _}, socket) do
    {:ok, load(socket)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = if Map.has_key?(socket.assigns, :pending), do: socket, else: load(socket)
    {:ok, socket}
  end

  def handle_event("submit", %{"request_id" => id} = params, socket) do
    case find(socket, id) do
      %QuestionRequest{} = request ->
        answers = Notifications.collect_answers(request.questions, params)
        _ = Notifications.answer_question_request(request.id, answers)
        {:noreply, load(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("approve", %{"id" => id}, socket), do: resolve(socket, id, "allow")
  def handle_event("deny", %{"id" => id}, socket), do: resolve(socket, id, "deny")

  defp resolve(socket, id, decision) do
    case find(socket, id) do
      %PermissionRequest{} ->
        _ = Notifications.resolve_permission_request(id, decision)
        {:noreply, load(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp find(socket, id), do: Enum.find(socket.assigns.pending, &(&1.id == id))

  defp load(socket) do
    user_id = socket.assigns.current_scope.user.id

    pending =
      user_id
      |> Notifications.list_pending_notifications()
      |> Enum.take(@limit)

    assign(socket, pending: pending, total: Notifications.count_pending_notifications(user_id))
  end

  def render(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <label
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-sm tooltip tooltip-left"
        data-tip="Notifications"
        data-test="notification-badge"
        data-count={@total}
      >
        <span class="indicator">
          <span :if={@total > 0} class="indicator-item badge badge-primary badge-xs">
            {@total}
          </span>
          <.icon name="hero-inbox" class="size-5" />
        </span>
      </label>
      <div
        tabindex="0"
        class="dropdown-content menu bg-base-100 border border-base-300 rounded-box z-[1] w-96 max-h-[70dvh] overflow-y-auto shadow-lg mt-2 p-3 space-y-3"
      >
        <p :if={@pending == []} class="text-center text-sm opacity-60 py-6">
          Nothing waiting on you.
        </p>
        <.notification_item :for={item <- @pending} item={item} target={@myself} />
        <.link
          navigate={~p"/app/notifications"}
          class="link link-primary block border-t border-base-300 pt-2 text-center text-xs"
        >
          View all
        </.link>
      </div>
    </div>
    """
  end

  attr :item, :any, required: true
  attr :target, :any, required: true

  defp notification_item(%{item: %QuestionRequest{}} = assigns) do
    ~H"""
    <ChatComponents.question
      id={"notif-dropdown-question-#{@item.id}"}
      request={@item}
      on_submit="submit"
      target={@target}
    />
    """
  end

  defp notification_item(%{item: %PermissionRequest{}} = assigns) do
    ~H"""
    <PermissionComponents.permission_request
      id={"notif-dropdown-permission-#{@item.id}"}
      request={@item}
      on_approve="approve"
      on_deny="deny"
      target={@target}
    />
    """
  end
end
