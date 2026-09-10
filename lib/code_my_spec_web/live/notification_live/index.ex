defmodule CodeMySpecWeb.NotificationLive.Index do
  @moduledoc """
  Notifications inbox: lists the user's remote questions and permission
  requests — pending first, recent history below — so a missed push
  notification is never the only way to find them. Items link to the
  existing answer surfaces (`QuestionLive.Show`, `PermissionLive.Show`).
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest

  # A scroll increment for "Recent", not a cap — `more_resolved?` says whether
  # another page exists, and the viewport-bottom hook keeps asking for one
  # until it doesn't.
  @resolved_page 20

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket), do: Notifications.subscribe_notifications_list(user_id)

    {:ok,
     socket
     |> assign(page_title: "Notifications", selected: MapSet.new())
     |> load_notifications()}
  end

  @impl true
  def handle_info({:notifications_changed}, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("load_more_resolved", _params, socket) do
    {:noreply, load_more_resolved(socket)}
  end

  # Permission requests only. `QuestionRequest` is deliberately answer-only —
  # story 896 decided against a way for a question to disappear without the
  # user having answered it, and a bulk clear is the same disappearance at a
  # larger scale. A permission request already has "expired" in its own
  # status list for exactly this: a human looking at the backlog and deciding
  # a request no longer matters, one row or many.
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, id) do
        MapSet.delete(socket.assigns.selected, id)
      else
        MapSet.put(socket.assigns.selected, id)
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all_pending_permissions", _params, socket) do
    ids = for %{type: :permission, id: id} <- socket.assigns.pending, do: id
    {:noreply, assign(socket, :selected, MapSet.new(ids))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("dismiss_selected", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    ids = MapSet.to_list(socket.assigns.selected)
    count = Notifications.bulk_dismiss_permission_requests(ids, user_id)

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> put_flash(:info, "Dismissed #{count} request#{if count == 1, do: "", else: "s"}.")
     |> load_notifications()}
  end

  defp load_notifications(socket) do
    user_id = socket.assigns.current_scope.user.id

    pending =
      user_id
      |> Notifications.list_pending_notifications()
      |> Enum.map(&to_item/1)

    resolved =
      user_id
      |> Notifications.list_resolved_notifications(limit: @resolved_page)
      |> Enum.map(&to_item/1)

    assign(socket,
      pending: pending,
      resolved: resolved,
      more_resolved?: length(resolved) >= @resolved_page
    )
  end

  # Re-fetching by the oldest item already on screen (rather than an offset)
  # means a resolution landing between pages neither duplicates nor skips a
  # row — the cursor is a value in the data, not a position in a list that
  # just changed size.
  defp load_more_resolved(%{assigns: %{resolved: []}} = socket), do: socket

  defp load_more_resolved(socket) do
    user_id = socket.assigns.current_scope.user.id
    resolved = socket.assigns.resolved
    oldest_at = List.last(resolved).inserted_at
    seen_ids = for %{inserted_at: ^oldest_at, id: id} <- resolved, do: id

    more =
      user_id
      |> Notifications.list_resolved_notifications(
        limit: @resolved_page,
        before: {oldest_at, seen_ids}
      )
      |> Enum.map(&to_item/1)

    socket
    |> update(:resolved, &(&1 ++ more))
    |> assign(:more_resolved?, length(more) >= @resolved_page)
  end

  defp to_item(%QuestionRequest{} = r) do
    %{
      id: r.id,
      type: :question,
      title: r.title || first_question(r.questions),
      body: first_question(r.questions),
      status: r.status,
      inserted_at: r.inserted_at,
      path: ~p"/app/questions/#{r.id}"
    }
  end

  defp to_item(%PermissionRequest{} = r) do
    %{
      id: r.id,
      type: :permission,
      title: "Claude Code: #{r.tool_name}",
      body: tool_summary(r),
      status: r.status,
      inserted_at: r.inserted_at,
      path: ~p"/app/permissions/#{r.id}"
    }
  end

  defp first_question([%{"question" => q} | _]) when is_binary(q), do: q
  defp first_question(_), do: "Claude Code has a question"

  defp tool_summary(%{tool_input: %{"command" => cmd}}), do: cmd
  defp tool_summary(%{tool_input: %{"file_path" => path}}), do: path
  defp tool_summary(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="mx-auto max-w-2xl">
        <.header>
          Notifications
          <:subtitle>Questions and approvals from Claude Code</:subtitle>
        </.header>

        <div :if={@pending == [] and @resolved == []} class="py-16 text-center opacity-60">
          <.icon name="hero-inbox" class="mx-auto size-10 mb-3" />
          <p>Nothing here yet — Claude's questions and permission requests will show up here.</p>
        </div>

        <section :if={@pending != []} class="mt-6">
          <div class="mb-2 flex items-center justify-between gap-2">
            <h2 class="text-sm font-semibold uppercase tracking-wide opacity-60">Pending</h2>
            <div :if={any_permissions?(@pending)} class="flex items-center gap-3 text-xs">
              <button
                type="button"
                phx-click="select_all_pending_permissions"
                class="link opacity-70 hover:opacity-100"
              >
                Select all
              </button>
              <button
                :if={MapSet.size(@selected) > 0}
                type="button"
                phx-click="clear_selection"
                class="link opacity-70 hover:opacity-100"
              >
                Clear
              </button>
            </div>
          </div>

          <div
            :if={MapSet.size(@selected) > 0}
            class="mb-2 flex items-center justify-between rounded-box border border-primary/30 bg-primary/5 px-3 py-2 text-sm"
          >
            <span>{MapSet.size(@selected)} selected</span>
            <button
              type="button"
              phx-click={show_confirm("confirm-dismiss-selected")}
              class="btn btn-error btn-xs"
              data-test="dismiss-selected"
            >
              Dismiss
            </button>
          </div>

          <.confirm_dialog
            id="confirm-dismiss-selected"
            title="Dismiss the selected requests?"
            confirm_label="Dismiss"
            on_confirm={JS.push("dismiss_selected")}
          />

          <ul class="space-y-2">
            <.item
              :for={item <- @pending}
              item={item}
              selectable?={true}
              selected={MapSet.member?(@selected, item.id)}
            />
          </ul>
        </section>

        <section :if={@resolved != []} class="mt-8">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-60 mb-2">Recent</h2>
          <ul
            id="resolved-notifications"
            class="space-y-2"
            phx-viewport-bottom={@more_resolved? && "load_more_resolved"}
            data-more-resolved={to_string(@more_resolved?)}
          >
            <.item :for={item <- @resolved} item={item} />
            <p
              :if={@more_resolved?}
              data-test="loading-more"
              class="py-2 text-center text-xs opacity-40"
            >
              loading more…
            </p>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true
  attr :selectable?, :boolean, default: false
  attr :selected, :boolean, default: false

  defp item(assigns) do
    ~H"""
    <li
      data-test="notification"
      data-id={@item.id}
      data-kind={@item.type}
      data-status={@item.status}
      class="flex items-start gap-2"
    >
      <input
        :if={@selectable? && @item.type == :permission}
        type="checkbox"
        class="checkbox checkbox-sm mt-4 shrink-0"
        checked={@selected}
        phx-click="toggle_select"
        phx-value-id={@item.id}
        data-test="select-notification"
      />
      <.link
        navigate={@item.path}
        class={[
          "card card-compact border bg-base-100 hover:bg-base-200 transition-colors block min-w-0 flex-1",
          @item.status == "pending" && "border-primary/40",
          @item.status != "pending" && "border-base-300 opacity-75"
        ]}
      >
        <div class="card-body flex-row items-start gap-3">
          <.icon
            name={
              if @item.type == :question, do: "hero-chat-bubble-left-right", else: "hero-shield-check"
            }
            class={"size-5 mt-0.5 shrink-0#{if @item.status == "pending", do: " text-primary"}"}
          />
          <div class="min-w-0 flex-1">
            <p class="font-medium truncate">{@item.title}</p>
            <p :if={@item.body && @item.body != @item.title} class="text-sm opacity-60 truncate">
              {@item.body}
            </p>
          </div>
          <div class="flex flex-col items-end gap-1 shrink-0">
            <span class={["badge badge-sm", status_class(@item.status)]}>{@item.status}</span>
            <time class="text-xs opacity-50">
              {Calendar.strftime(@item.inserted_at, "%b %-d, %H:%M")}
            </time>
          </div>
        </div>
      </.link>
    </li>
    """
  end

  defp any_permissions?(items), do: Enum.any?(items, &(&1.type == :permission))

  defp status_class("pending"), do: "badge-primary"
  defp status_class("answered"), do: "badge-success"
  defp status_class("approved"), do: "badge-success"
  defp status_class("denied"), do: "badge-error"
  defp status_class("expired"), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"
end
