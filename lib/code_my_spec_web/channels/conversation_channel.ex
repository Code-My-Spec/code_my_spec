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

  alias CodeMySpec.AppTokens
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Issues
  alias CodeMySpec.Projects
  alias CodeMySpec.Uploads
  alias CodeMySpecWeb.Presence

  @impl true
  def join("conversation:" <> topic_user_id, _payload, socket) do
    email = socket.assigns[:end_user_email]

    cond do
      topic_user_id != socket.assigns[:end_user_id] ->
        Logger.warning(
          "[ConversationChannel] join rejected — user mismatch topic=#{topic_user_id} socket=#{inspect(socket.assigns[:end_user_id])}"
        )

        {:error, %{reason: "unauthorized"}}

      # Conversations thread on email; without one the conversation insert
      # would fail validation and crash the join. Reject cleanly instead so
      # integrations that omitted `user_email` on connect get a usable error.
      not (is_binary(email) and email != "") ->
        Logger.warning(
          "[ConversationChannel] join rejected — no end_user_email topic=#{topic_user_id}"
        )

        {:error, %{reason: "email required"}}

      true ->
        account_id = resolve_account_id(socket)

        {:ok, conversation} =
          Conversations.find_or_create_conversation(
            account_id,
            socket.assigns.project_id,
            email,
            end_user_id: socket.assigns.end_user_id
          )

        socket =
          socket
          |> assign(:account_id, account_id)
          |> assign(:conversation, conversation)

        send(self(), :after_join)
        {:ok, socket}
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
  @doc """
  Swap in a fresh socket token without dropping the connection.

  A socket token ages out in fifteen minutes; a conversation does not. The
  widget fetches a new one and sends it here, and the connection carries on —
  criterion 8055 is that a visitor mid-conversation notices nothing, and a
  disconnect/reconnect is noticed even when it is fast, because the socket
  drops messages in flight and the channel rejoins from scratch.

  A token for a *different* project is refused rather than accepted, because
  accepting it would silently move an open conversation between projects.
  Refusal leaves the existing credential in place — the visitor keeps the
  session they already had, and only loses it when it genuinely expires.
  """
  def handle_in("reauth", %{"socket_token" => token}, socket) when is_binary(token) do
    case AppTokens.verify_socket_token(token) do
      {:ok, %{id: id}} ->
        if id == socket.assigns[:project_id] do
          {:reply, {:ok, %{status: "ok"}}, socket}
        else
          Logger.warning("[ConversationChannel] reauth refused — token names a different project")
          {:reply, {:error, %{reason: "project_mismatch"}}, socket}
        end

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("reauth", _payload, socket) do
    {:reply, {:error, %{reason: "missing_socket_token"}}, socket}
  end

  def handle_in("send_message", payload, socket) do
    body = Map.get(payload, "body", "")
    attachments = valid_chat_attachments(Map.get(payload, "attachments"), socket.assigns.project_id)

    case Conversations.add_message(
           socket.assigns.conversation,
           :user,
           body,
           socket.assigns.end_user_id,
           attachments
         ) do
      {:ok, _message} -> {:reply, :ok, socket}
      {:error, _changeset} -> {:reply, {:error, %{reason: "message rejected"}}, socket}
    end
  end

  # Presigned S3 URL for a file the customer wants to attach to a chat message —
  # the bytes go browser→S3, never over the socket. Keyed under the project's
  # `chat/` prefix; the client PUTs then sends the `s3_key` with `send_message`.
  def handle_in("request_chat_upload", params, socket) do
    content_type = Map.get(params, "content_type", "application/octet-stream")
    key = "chat/#{socket.assigns.project_id}/#{Ecto.UUID.generate()}/#{safe_name(params["filename"])}"

    case Uploads.presigned_upload_url(key, content_type) do
      {:ok, url} -> {:reply, {:ok, %{upload_url: url, s3_key: key}}, socket}
      {:error, _reason} -> {:reply, {:error, %{reason: "could not presign upload"}}, socket}
    end
  end

  # Hand the widget a presigned S3 URL so the browser uploads a screenshot's
  # bytes straight to our bucket — the image never rides this socket. The key is
  # scoped to the project's `issues/` prefix; the client PUTs to `upload_url`
  # then reports the `s3_key` back with `submit_feedback`.
  def handle_in("request_screenshot_upload", params, socket) do
    content_type = Map.get(params, "content_type", "image/png")
    key = Uploads.generate_key(socket.assigns.project_id, screenshot_filename(content_type))

    case Uploads.presigned_upload_url(key, content_type) do
      {:ok, url} -> {:reply, {:ok, %{upload_url: url, s3_key: key}}, socket}
      {:error, _reason} -> {:reply, {:error, %{reason: "could not presign upload"}}, socket}
    end
  end

  # The support widget's "Report a problem" tab rides the same deploy-key
  # connection as chat: a `submit_feedback` event files an issue on the project
  # (source "widget"), which broadcasts like any other issue so the operator
  # dashboard and local mirrors pick it up. Reporting and chatting are one
  # widget, one connection. A screenshot, if any, was already uploaded to S3 via
  # `request_screenshot_upload`; only its `screenshot_key` travels here.
  def handle_in("submit_feedback", payload, socket) do
    attrs =
      %{
        "title" => Map.get(payload, "title"),
        "description" => Map.get(payload, "description"),
        "severity" => Map.get(payload, "severity") || "medium"
      }
      |> attach_screenshot(payload, socket.assigns.project_id)

    case Issues.report_from_widget(socket.assigns.account_id, socket.assigns.project_id, attrs) do
      {:ok, issue} ->
        {:reply, {:ok, %{id: issue.id}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "could not file issue"}}, socket}
    end
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

  # Attach a screenshot the browser already uploaded to S3. Only accept a key
  # under this project's own `issues/` prefix (the client can't smuggle in
  # another project's object).
  defp attach_screenshot(attrs, payload, project_id) do
    key = payload["screenshot_key"]

    if is_binary(key) and String.starts_with?(key, "issues/#{project_id}/") do
      attachment = %{
        "type" => "screenshot",
        "s3_key" => key,
        "content_type" => payload["screenshot_content_type"] || "image/png"
      }

      Map.put(attrs, "attachments", [attachment])
    else
      attrs
    end
  end

  defp screenshot_filename("image/jpeg"), do: "screenshot.jpg"
  defp screenshot_filename("image/webp"), do: "screenshot.webp"
  defp screenshot_filename(_content_type), do: "screenshot.png"

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
      attachments: Enum.map(message.attachments || [], &attachment_payload/1),
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  # The widget renders from a short-lived presigned GET URL (it can't hit our
  # authenticated endpoints); it's re-minted on each replay so it's never stale.
  defp attachment_payload(%{"s3_key" => key} = attachment) do
    url =
      case Uploads.presigned_download_url(key) do
        {:ok, u} -> u
        _ -> nil
      end

    %{
      filename: attachment["filename"],
      content_type: attachment["content_type"],
      size: attachment["size"],
      url: url
    }
  end

  defp attachment_payload(_attachment), do: %{}

  # Keep only attachments the client uploaded under this project's own prefix.
  defp valid_chat_attachments(list, project_id) when is_list(list) do
    prefix = "chat/#{project_id}/"

    for a <- list, is_map(a), is_binary(a["s3_key"]), String.starts_with?(a["s3_key"], prefix) do
      %{
        "s3_key" => a["s3_key"],
        "filename" => a["filename"],
        "content_type" => a["content_type"],
        "size" => a["size"]
      }
    end
  end

  defp valid_chat_attachments(_list, _project_id), do: []

  defp safe_name(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "file"
      cleaned -> cleaned
    end
  end

  defp safe_name(_name), do: "file"

  defp broadcast_presence_changed(socket) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      Conversations.inbox_topic(socket.assigns.account_id),
      {:presence_changed}
    )
  end
end
