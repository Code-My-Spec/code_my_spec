defmodule CodeMySpecWeb.InboxLive do
  @moduledoc """
  The operator's unified inbox. `:index` lists every conversation across the
  account's projects as a table (live presence + last-message preview); `:show`
  opens one conversation as an auto-scrolling DaisyUI chat thread the operator
  can reply to in real time. Any CMS user in the account can read and reply.

  Styling mirrors the vetted MarketMySpec ChatLive patterns (table index,
  chat-bubble thread, colocated auto-scroll hook), rendered in CodeMySpec's
  own theme.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Conversations
  alias CodeMySpecWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Conversations.inbox_topic(scope.active_account_id))
    end

    {:ok,
     socket
     |> assign(:conversation, nil)
     |> assign(:messages, [])
     |> load_list()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    # Opening a conversation marks it read for the whole account.
    {:ok, conversation} = Conversations.mark_read(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:conversation, conversation)
     |> assign(:messages, Conversations.list_messages(conversation))
     |> assign(:page_title, conversation.end_user_email)
     |> load_list()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:conversation, nil) |> assign(:page_title, "Chats")}
  end

  @impl true
  def handle_event("open_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/app/inbox/#{id}")}
  end

  def handle_event("start_conversation", %{"conversation" => %{"email" => email, "body" => body}}, socket) do
    {:ok, conversation} = Conversations.start_conversation(socket.assigns.current_scope, email, body)
    # A freshly-started thread means the customer isn't here yet — email them.
    maybe_notify_offline(conversation, body, socket.assigns.online)
    {:noreply, push_navigate(socket, to: ~p"/app/inbox/#{conversation.id}")}
  end

  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body)

    if body != "" do
      {:ok, _message} = Conversations.reply(socket.assigns.current_scope, socket.assigns.conversation.id, body)
      maybe_notify_offline(socket.assigns.conversation, body, socket.assigns.online)
    end

    {:noreply, reload_thread(socket)}
  end

  def handle_event("close_conversation", _params, socket) do
    {:ok, conversation} =
      Conversations.set_status(socket.assigns.current_scope, socket.assigns.conversation.id, :closed)

    {:noreply, socket |> assign(:conversation, conversation) |> load_list()}
  end

  def handle_event("reopen_conversation", _params, socket) do
    {:ok, conversation} =
      Conversations.set_status(socket.assigns.current_scope, socket.assigns.conversation.id, :open)

    {:noreply, socket |> assign(:conversation, conversation) |> load_list()}
  end

  def handle_event("load_older", _params, socket) do
    older =
      case socket.assigns.messages do
        [%{inserted_at: before} | _] ->
          Conversations.list_messages(socket.assigns.conversation, before: before)

        _ ->
          []
      end

    {:noreply, assign(socket, :messages, older ++ socket.assigns.messages)}
  end

  @impl true
  def handle_info({:inbox_updated, conversation_id}, socket) do
    socket = load_list(socket)

    socket =
      if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
        reload_thread(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:presence_changed}, socket), do: {:noreply, load_list(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_list(socket) do
    scope = socket.assigns.current_scope

    online =
      scope.active_account_id
      |> Conversations.presence_topic()
      |> Presence.list()
      |> Map.keys()
      |> MapSet.new()

    socket
    |> assign(:conversations, Conversations.list_conversations(scope))
    |> assign(:online, online)
    |> assign(:unread_count, Conversations.unread_count(scope))
  end

  # Email the customer only when they're not currently connected via the widget.
  defp maybe_notify_offline(conversation, body, online) do
    unless online?(conversation, online) do
      Conversations.notify_offline_reply(conversation, body)
    end
  end

  defp reload_thread(%{assigns: %{conversation: nil}} = socket), do: socket

  defp reload_thread(socket) do
    assign(socket, :messages, Conversations.list_messages(socket.assigns.conversation))
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_notifications={@pending_notifications}>
      <div class="mx-auto w-full max-w-4xl">
        <header class="flex items-center justify-between gap-3 pb-4">
          <div class="flex items-center gap-2">
            <h1 class="text-2xl font-semibold">Chats</h1>
            <span :if={@unread_count > 0} data-test="unread-count" class="badge badge-primary badge-sm">
              {@unread_count} unread
            </span>
          </div>

          <details class="relative z-50" data-test="new-chat-menu">
            <summary class="btn btn-primary btn-sm list-none [&::-webkit-details-marker]:hidden">
              <.icon name="hero-plus" class="size-4" /> New chat
            </summary>
            <div class="absolute right-0 top-full z-50 mt-1 w-80 rounded-box bg-base-200 p-3 shadow">
              <form phx-submit="start_conversation" data-test="new-conversation-form" class="flex flex-col gap-2">
                <input
                  type="email"
                  name="conversation[email]"
                  placeholder="user@example.com"
                  class="input input-bordered input-sm"
                />
                <input
                  type="text"
                  name="conversation[body]"
                  placeholder="Message"
                  class="input input-bordered input-sm"
                />
                <button type="submit" class="btn btn-primary btn-sm">Start chat</button>
              </form>
            </div>
          </details>
        </header>

        <div class="overflow-x-auto">
          <table class="table" data-test="conversations">
            <thead>
              <tr>
                <th>User</th>
                <th>Status</th>
                <th class="hidden sm:table-cell">Last message</th>
                <th class="hidden sm:table-cell">Last active</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@conversations == []} data-test="conversations-empty">
                <td colspan="4" class="text-center opacity-60">No conversations yet</td>
              </tr>
              <tr
                :for={conversation <- @conversations}
                data-test="conversation"
                data-unread={to_string(!conversation.read)}
                phx-click="open_conversation"
                phx-value-id={conversation.id}
                class={["cursor-pointer hover", conversation.status == :closed && "opacity-50"]}
              >
                <td data-test="conversation-user" class={["break-all", if(conversation.read, do: "font-medium", else: "font-bold")]}>
                  <span
                    :if={!conversation.read}
                    data-test="unread-dot"
                    class="mr-1.5 inline-block size-2 rounded-full bg-primary align-middle"
                  >
                  </span>
                  {conversation.end_user_email}
                  <span :if={conversation.status == :closed} class="badge badge-ghost badge-xs ml-1">Closed</span>
                </td>
                <td>
                  <span
                    data-test={"presence-#{conversation.end_user_id}"}
                    class={["badge badge-sm", if(online?(conversation, @online), do: "badge-success", else: "badge-ghost")]}
                  >
                    {presence_label(conversation, @online)}
                  </span>
                </td>
                <td data-test="conversation-preview" class="hidden max-w-xs truncate opacity-70 sm:table-cell">
                  {preview(conversation)}
                </td>
                <td class="hidden text-sm opacity-60 sm:table-cell">
                  {Calendar.strftime(conversation.updated_at, "%Y-%m-%d %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_notifications={@pending_notifications}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatScroll">
        export default {
          mounted() {
            this.scroll();
            this.observer = new MutationObserver(() => this.scroll());
            this.observer.observe(this.el, { childList: true, subtree: true });
          },
          destroyed() { this.observer && this.observer.disconnect(); },
          scroll() { this.el.scrollTop = this.el.scrollHeight; }
        }
      </script>

      <div
        data-test="chat"
        data-chat-id={@conversation.id}
        style="height: calc(100dvh - 7rem)"
        class="mx-auto flex w-full max-w-3xl flex-col"
      >
        <header class="flex shrink-0 items-center justify-between gap-3 border-b border-base-300 pb-3">
          <div class="flex min-w-0 items-center gap-2">
            <.link navigate={~p"/app/inbox"} data-test="back-to-chats" class="btn btn-ghost btn-xs shrink-0">
              <.icon name="hero-arrow-left" class="size-4" /> Chats
            </.link>
            <h1 class="truncate text-lg font-semibold">{@conversation.end_user_email}</h1>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <span
              data-test={"presence-#{@conversation.end_user_id}"}
              class={["badge badge-sm", if(online?(@conversation, @online), do: "badge-success", else: "badge-ghost")]}
            >
              {presence_label(@conversation, @online)}
            </span>
            <button
              :if={@conversation.status == :open}
              type="button"
              phx-click="close_conversation"
              data-test="close-conversation"
              class="btn btn-ghost btn-xs gap-1"
            >
              <.icon name="hero-check" class="size-4" /> Close
            </button>
            <button
              :if={@conversation.status == :closed}
              type="button"
              phx-click="reopen_conversation"
              data-test="reopen-conversation"
              class="btn btn-ghost btn-xs gap-1"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Reopen
            </button>
          </div>
        </header>

        <div id="messages-scroll" phx-hook=".ChatScroll" class="min-h-0 flex-1 overflow-y-auto py-4">
          <div data-test="thread" class="space-y-1">
            <div class="flex justify-center">
              <button
                :if={@messages != []}
                type="button"
                phx-click="load_older"
                data-test="chat-load-older"
                class="btn btn-ghost btn-xs"
              >
                Load older messages
              </button>
            </div>

            <div
              :for={message <- @messages}
              data-test="message"
              data-role={message.role}
              class={["chat", chat_side(message.role)]}
            >
              <div class="chat-header text-xs opacity-60">{sender_label(message.role)}</div>
              <div class={["chat-bubble break-words", chat_bubble(message.role)]}>
                <p :if={message.body not in [nil, ""]} class="whitespace-pre-wrap">{message.body}</p>
                <div :for={{att, idx} <- Enum.with_index(message.attachments || [])} class="mt-1">
                  <a
                    :if={image_attachment?(att)}
                    href={~p"/app/inbox/messages/#{message.id}/attachments/#{idx}"}
                    target="_blank"
                    rel="noopener"
                  >
                    <img
                      src={~p"/app/inbox/messages/#{message.id}/attachments/#{idx}"}
                      alt={att["filename"]}
                      class="max-h-48 rounded"
                    />
                  </a>
                  <a
                    :if={not image_attachment?(att)}
                    href={~p"/app/inbox/messages/#{message.id}/attachments/#{idx}"}
                    target="_blank"
                    rel="noopener"
                    class="inline-flex items-center gap-1 text-sm underline"
                  >
                    <.icon name="hero-paper-clip" class="size-4" /> {att["filename"]}
                  </a>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="shrink-0 border-t border-base-300 pt-3">
          <form phx-submit="send_message" data-test="message-form" class="flex gap-2">
            <input
              type="text"
              name="message[body]"
              value=""
              placeholder="Send a message"
              autocomplete="off"
              class="input input-bordered flex-1"
            />
            <button type="submit" class="btn btn-primary">Send</button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Helpers ----------------------------------------------------------------

  defp preview(conversation) do
    case List.last(conversation.messages) do
      nil -> ""
      message -> message.body
    end
  end

  defp online?(%{end_user_id: end_user_id}, online) when is_binary(end_user_id),
    do: MapSet.member?(online, end_user_id)

  defp online?(_conversation, _online), do: false

  defp presence_label(conversation, online),
    do: if(online?(conversation, online), do: "Online", else: "Offline")

  defp image_attachment?(%{"content_type" => ct}) when is_binary(ct),
    do: String.starts_with?(ct, "image/")

  defp image_attachment?(_attachment), do: false

  defp chat_side(:operator), do: "chat-end"
  defp chat_side(_role), do: "chat-start"

  defp chat_bubble(:operator), do: "chat-bubble-primary"
  defp chat_bubble(_role), do: "bg-base-200 text-base-content"

  defp sender_label(:operator), do: "You"
  defp sender_label(:assistant), do: "Assistant"
  defp sender_label(_role), do: "User"
end
