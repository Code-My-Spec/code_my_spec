defmodule CodeMySpecWeb.ConversationChannel do
  @moduledoc """
  The end-user's side of a chat, over topic `"conversation:<end_user_id>"`.

  A socket may only join its own end-user's topic — joining another user's
  conversation is rejected (end-user isolation). On join the server resolves
  (or creates) the conversation by the end-user's email, replays history as
  `"new_message"` pushes, tracks presence so the operator inbox sees the user
  online, and forwards subsequent messages live. `"send_message"` persists a
  user-authored message and fans it out to the operator inbox.
  """

  use CodeMySpecWeb, :channel
  require Logger

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Projects
  alias CodeMySpecWeb.Presence

  @impl true
  def join("conversation:" <> topic_user_id, _payload, socket) do
    if topic_user_id == socket.assigns[:end_user_id] do
      account_id = resolve_account_id(socket)

      {:ok, conversation} =
        Conversations.find_or_create_conversation(
          account_id,
          socket.assigns.project_id,
          socket.assigns.end_user_email,
          end_user_id: socket.assigns.end_user_id
        )

      socket =
        socket
        |> assign(:account_id, account_id)
        |> assign(:conversation, conversation)

      send(self(), :after_join)
      {:ok, socket}
    else
      Logger.warning(
        "[ConversationChannel] join rejected — user mismatch topic=#{topic_user_id} socket=#{inspect(socket.assigns[:end_user_id])}"
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    conversation = socket.assigns.conversation

    # Replay history so a returning / newly-connected user receives every
    # message that landed while they were away.
    for message <- Conversations.list_messages(conversation) do
      push(socket, "new_message", message_payload(message))
    end

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Conversations.conversation_topic(conversation.id))

    if socket.assigns.end_user_id do
      {:ok, _ref} =
        Presence.track(
          self(),
          Conversations.presence_topic(socket.assigns.account_id),
          socket.assigns.end_user_id,
          %{online_at: System.system_time(:second)}
        )

      broadcast_presence_changed(socket)
    end

    {:noreply, socket}
  end

  # Live delivery: a message persisted elsewhere (operator reply, or another of
  # this user's connections) arrives on the per-conversation topic.
  def handle_info({:new_message, %Message{} = message}, socket) do
    push(socket, "new_message", message_payload(message))
    {:noreply, socket}
  end

  @impl true
  def handle_in("send_message", %{"body" => body}, socket) do
    {:ok, _message} =
      Conversations.add_message(socket.assigns.conversation, :user, body, socket.assigns.end_user_id)

    {:reply, :ok, socket}
  end

  # Scroll-up pagination: the client sends the `inserted_at` of the oldest
  # message it currently holds; the server replies with the previous page
  # (oldest-first) for the client to prepend.
  def handle_in("load_older", %{"before" => before}, socket) do
    case DateTime.from_iso8601(before) do
      {:ok, before_dt, _offset} ->
        messages =
          socket.assigns.conversation
          |> Conversations.list_messages(before: before_dt)
          |> Enum.map(&message_payload/1)

        {:reply, {:ok, %{messages: messages}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "invalid cursor"}}, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:account_id] && socket.assigns[:end_user_id] do
      Presence.untrack(
        self(),
        Conversations.presence_topic(socket.assigns.account_id),
        socket.assigns.end_user_id
      )

      broadcast_presence_changed(socket)
    end

    :ok
  end

  defp resolve_account_id(socket) do
    case socket.assigns[:account_id] do
      nil -> Projects.get_project_by_id(socket.assigns.project_id).account_id
      account_id -> account_id
    end
  end

  defp message_payload(%Message{} = message) do
    %{
      id: message.id,
      body: message.body,
      role: message.role,
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp broadcast_presence_changed(socket) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      Conversations.inbox_topic(socket.assigns.account_id),
      {:presence_changed}
    )
  end
end
