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

  ## Summary first, full form on click

  The panel lists compact rows — icon, title, one line of body — the same
  shape `NotificationLive.Index` already uses for "Pending". Clicking a row
  is the only way to reach the full form; `@expanded` names at most one
  request at a time, and submitting always collapses back to the list. This
  matches the standalone inbox's own two-step shape (list, then a page to
  answer on) without the navigation — expanding swaps content inside the one
  card already on screen rather than opening a second surface.

  ## Why a resolved item is never removed mid-panel

  The panel opens via a plain daisyUI `dropdown`/`dropdown-content` pair —
  `:focus-within`, no JS, no server round trip to open it. Submitting an item
  legitimately drops it from `@pending` (it is no longer pending) and that is
  fine here specifically because the row that had focus — the submit button,
  inside the expanded form — goes with it deliberately, the same as a modal
  closing after its own action completes. What must never happen is an
  *unrelated* pending item disappearing as a side effect of one submit;
  `load/1` only ever removes items the server now says are resolved.

  ## Why a flash, not an inline "sent" banner

  `ChatComponents.question/1`'s "Answer sent" banner makes sense on its own
  page, where the page is the whole context. Inside a dropdown that is about
  to collapse (the item leaves `@pending` the moment it resolves), a banner
  nobody stays to read is wasted; the flash relayed through `NotificationsHook`
  (see below) says the same thing where the user's eyes already are once the
  panel closes.
  """
  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpecWeb.ChatComponents
  alias CodeMySpecWeb.PermissionComponents
  alias Phoenix.LiveView.JS

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
  #
  # `@expanded` is left untouched by a broadcast-driven refresh: another tab
  # resolving a different request should not collapse the one this user has
  # open.
  def update(%{refresh: _}, socket) do
    {:ok, load(socket)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :pending) do
        socket
      else
        socket |> assign(:expanded, nil) |> load()
      end

    {:ok, socket}
  end

  def handle_event("expand", %{"id" => id}, socket), do: {:noreply, assign(socket, :expanded, id)}
  def handle_event("collapse", _params, socket), do: {:noreply, assign(socket, :expanded, nil)}

  def handle_event("submit", %{"request_id" => id} = params, socket) do
    case find(socket, id) do
      %QuestionRequest{} = request ->
        answers = Notifications.collect_answers(request.questions, params)
        _ = Notifications.answer_question_request(request.id, answers)
        {:noreply, socket |> flash(:info, "Answer sent.") |> collapse() |> load()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("approve", %{"id" => id}, socket),
    do: resolve(socket, id, "allow", "Approved.")

  def handle_event("deny", %{"id" => id}, socket), do: resolve(socket, id, "deny", "Denied.")

  defp resolve(socket, id, decision, message) do
    case find(socket, id) do
      %PermissionRequest{} ->
        _ = Notifications.resolve_permission_request(id, decision)
        {:noreply, socket |> flash(:info, message) |> collapse() |> load()}

      _ ->
        {:noreply, socket}
    end
  end

  # Not `put_flash/3` directly — see `NotificationsHook`'s moduledoc. A
  # `LiveComponent`'s own flash assign is discarded unless that same
  # component also redirects, so the actual `put_flash/3` call has to happen
  # one level up, on the LiveView process this component always runs inside.
  defp flash(socket, kind, message) do
    send(self(), {:notification_flash, kind, message})
    socket
  end

  defp collapse(socket), do: assign(socket, :expanded, nil)

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
    <div id={@id} class="dropdown dropdown-end">
      <label
        id={trigger_id(@id)}
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
        class="dropdown-content menu flex-nowrap bg-base-100 border border-base-300 rounded-box z-[1] w-96 max-h-[70dvh] overflow-y-auto shadow-lg mt-2 p-3 space-y-3"
      >
        <%!-- daisyUI's `.menu` sets `flex-wrap: wrap`, meant for a menu's own
        items to wrap within one row. Here, with height capped by
        `max-h-[70dvh]`, that wrap kicked in on the OTHER axis: once the
        stacked cards outgrew the panel's height, the flex column laid out a
        second column to their right instead of leaving them to
        `overflow-y-auto` — items marched rightward instead of scrolling.
        `flex-nowrap` forces the single column `overflow-y-auto` assumes. --%>

        <p :if={@pending == []} class="text-center text-sm opacity-60 py-6">
          Nothing waiting on you.
        </p>
        <.notification_item
          :for={item <- @pending}
          item={item}
          target={@myself}
          expanded={@expanded}
          dropdown_id={@id}
        />
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
  attr :expanded, :any, required: true
  attr :dropdown_id, :string, required: true

  defp notification_item(assigns) do
    ~H"""
    <.summary_row
      :if={@expanded != @item.id}
      item={@item}
      target={@target}
      dropdown_id={@dropdown_id}
    />
    <div :if={@expanded == @item.id}>
      <button
        type="button"
        phx-click={
          JS.push("collapse", target: @target) |> JS.focus(to: "##{trigger_id(@dropdown_id)}")
        }
        class="btn btn-ghost btn-xs -ml-1 mb-1"
      >
        <.icon name="hero-chevron-left" class="size-4" /> Back
      </button>
      <.expanded_form item={@item} target={@target} />
    </div>
    """
  end

  attr :item, :any, required: true
  attr :target, :any, required: true
  attr :dropdown_id, :string, required: true

  defp summary_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        JS.push("expand", value: %{"id" => @item.id}, target: @target)
        |> JS.focus(to: "##{trigger_id(@dropdown_id)}")
      }
      data-test="notification-summary"
      data-id={@item.id}
      class="card card-compact bg-base-100 hover:bg-base-200 transition-colors w-full text-left border border-primary/40"
    >
      <div class="card-body flex-row items-start gap-3">
        <.icon name={summary_icon(@item)} class="size-5 mt-0.5 shrink-0 text-primary" />
        <div class="min-w-0 flex-1">
          <p class="font-medium truncate">{summary_title(@item)}</p>
          <p :if={summary_body(@item)} class="text-sm opacity-60 truncate">
            {summary_body(@item)}
          </p>
        </div>
      </div>
    </button>
    """
  end

  # A plain `phx-click="expand"` swaps the clicked summary row for the
  # expanded form on the very next render — the whole point of this
  # interaction. Since the panel only stays open via CSS `:focus-within`, a
  # click that removes the element holding focus drops focus to nothing and
  # the *entire panel* snaps shut, hiding every other pending item along with
  # it. `JS.focus/2` runs client-side as part of the same click, ahead of the
  # server round trip that will remove the button, moving focus to the one
  # element in this component that is never removed: the bell that opens it.
  defp trigger_id(dropdown_id), do: "#{dropdown_id}-trigger"

  defp expanded_form(%{item: %QuestionRequest{}} = assigns) do
    ~H"""
    <ChatComponents.question
      id={"notif-dropdown-question-#{@item.id}"}
      request={@item}
      on_submit="submit"
      target={@target}
    />
    """
  end

  defp expanded_form(%{item: %PermissionRequest{}} = assigns) do
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

  defp summary_icon(%QuestionRequest{}), do: "hero-chat-bubble-left-right"
  defp summary_icon(%PermissionRequest{}), do: "hero-shield-check"

  defp summary_title(%QuestionRequest{title: title, questions: questions}),
    do: title || first_question(questions)

  defp summary_title(%PermissionRequest{tool_name: tool_name}), do: "Claude Code: #{tool_name}"

  defp summary_body(%QuestionRequest{questions: questions}), do: first_question(questions)
  defp summary_body(%PermissionRequest{} = request), do: tool_summary(request)

  defp first_question([%{"question" => q} | _]) when is_binary(q), do: q
  defp first_question(_), do: "Claude Code has a question"

  defp tool_summary(%{tool_input: %{"command" => cmd}}), do: cmd
  defp tool_summary(%{tool_input: %{"file_path" => path}}), do: path
  defp tool_summary(_), do: nil
end
