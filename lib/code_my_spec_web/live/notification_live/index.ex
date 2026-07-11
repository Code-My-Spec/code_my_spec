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

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket), do: Notifications.subscribe_notifications_list(user_id)

    {:ok,
     socket
     |> assign(page_title: "Notifications")
     |> load_notifications()}
  end

  @impl true
  def handle_info({:notifications_changed}, socket) do
    {:noreply, load_notifications(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_notifications(socket) do
    user_id = socket.assigns.current_scope.user.id

    {pending, resolved} =
      user_id
      |> Notifications.list_notifications()
      |> Enum.map(&to_item/1)
      |> Enum.split_with(&(&1.status == "pending"))

    assign(socket, pending: pending, resolved: resolved)
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
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-60 mb-2">Pending</h2>
          <ul class="space-y-2">
            <.item :for={item <- @pending} item={item} />
          </ul>
        </section>

        <section :if={@resolved != []} class="mt-8">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-60 mb-2">Recent</h2>
          <ul class="space-y-2">
            <.item :for={item <- @resolved} item={item} />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true

  defp item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@item.path}
        class={[
          "card card-compact border bg-base-100 hover:bg-base-200 transition-colors block",
          @item.status == "pending" && "border-primary/40",
          @item.status != "pending" && "border-base-300 opacity-75"
        ]}
      >
        <div class="card-body flex-row items-start gap-3">
          <.icon
            name={if @item.type == :question, do: "hero-chat-bubble-left-right", else: "hero-shield-check"}
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
            <time class="text-xs opacity-50">{Calendar.strftime(@item.inserted_at, "%b %-d, %H:%M")}</time>
          </div>
        </div>
      </.link>
    </li>
    """
  end

  defp status_class("pending"), do: "badge-primary"
  defp status_class("answered"), do: "badge-success"
  defp status_class("approved"), do: "badge-success"
  defp status_class("denied"), do: "badge-error"
  defp status_class("expired"), do: "badge-ghost"
  defp status_class(_), do: "badge-ghost"
end
