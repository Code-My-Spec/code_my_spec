defmodule CodeMySpec.Conversations do
  @moduledoc """
  Chat domain for operator (a CMS account) ↔ end-user messaging.

  A `Conversation` is one durable thread per end-user, scoped to an account and
  project; a `Message` carries a plain-text body and `(role, sender_id)`
  authorship with `:assistant` reserved for future LLM participants. Human↔human
  only in v1.

  Two faces:

    * **Widget side** (no CMS user scope) — `find_or_create_conversation/4`,
      `add_message/4`, `list_messages/1`. Driven by the deploy-key authenticated
      `ConversationChannel`.
    * **Operator side** (account `Scope`) — `list_conversations/1`,
      `start_conversation/3`, `reply/3`. Driven by `InboxLive`. Conversations are
      account-scoped, so any CMS user in the account can read and reply across
      every project the account owns.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo

  @default_page_size 50

  # ---- PubSub / presence topics ----

  @doc "Topic the operator inbox subscribes to for an account's new messages and presence changes."
  def inbox_topic(account_id), do: "inbox:#{account_id}"

  @doc "Presence topic tracking which of an account's end-users are currently connected."
  def presence_topic(account_id), do: "widget_presence:#{account_id}"

  @doc "Per-conversation topic the widget channel subscribes to for live delivery."
  def conversation_topic(conversation_id), do: "conversation:#{conversation_id}:messages"

  # ---- Widget side (account_id / project_id, no CMS scope) ----

  @doc """
  Finds the conversation for `(account_id, project_id, end_user_email)` or
  creates it. Backfills `end_user_id` the first time the target app's user id
  is known (e.g. an account-initiated thread that the user later connects to).
  """
  def find_or_create_conversation(account_id, project_id, end_user_email, opts \\ []) do
    end_user_id = Keyword.get(opts, :end_user_id)

    case Repo.get_by(Conversation,
           account_id: account_id,
           project_id: project_id,
           end_user_email: end_user_email
         ) do
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          account_id: account_id,
          project_id: project_id,
          end_user_email: end_user_email,
          end_user_id: end_user_id
        })
        |> Repo.insert()
        |> case do
          {:ok, conversation} -> {:ok, conversation}
          # Lost an insert race — fetch the now-existing row.
          {:error, _changeset} -> {:ok, get_conversation_by_email!(account_id, project_id, end_user_email)}
        end

      %Conversation{end_user_id: nil} = conversation when is_binary(end_user_id) ->
        conversation
        |> Conversation.changeset(%{end_user_id: end_user_id})
        |> Repo.update()

      conversation ->
        {:ok, conversation}
    end
  end

  defp get_conversation_by_email!(account_id, project_id, end_user_email) do
    Repo.get_by!(Conversation,
      account_id: account_id,
      project_id: project_id,
      end_user_email: end_user_email
    )
  end

  @doc """
  Appends a message to a conversation and broadcasts it on the per-conversation
  topic (for connected widgets) and the account inbox topic (for the operator).
  """
  def add_message(%Conversation{} = conversation, role, body, sender_id \\ nil) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      role: role,
      body: body,
      sender_id: sender_id
    })
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        touch(conversation)
        broadcast_new_message(conversation, message)
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  A page of messages for a conversation, oldest-first (ready to render).

  Paginated by default — returns the most recent `:limit` messages (default
  #{@default_page_size}). Pass `before: %DateTime{}` (the oldest message
  currently loaded) to fetch the previous page, powering scroll-up "load older"
  on the client.

  ## Options

    * `:limit` — page size (default #{@default_page_size})
    * `:before` — only messages strictly older than this `DateTime`
  """
  def list_messages(%Conversation{} = conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)

    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> before_cursor(Keyword.get(opts, :before))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp before_cursor(query, nil), do: query

  defp before_cursor(query, %DateTime{} = before),
    do: where(query, [m], m.inserted_at < ^before)

  # ---- Operator side (account Scope) ----

  @doc """
  All conversations for the scope's active account, across every project, with
  only the most recent page of messages preloaded per conversation (oldest-first
  for rendering). Older messages load on demand.
  """
  def list_conversations(scope) do
    Conversation
    |> where([c], c.account_id == ^scope.active_account_id)
    |> order_by([c], asc: c.inserted_at)
    |> preload([c], messages: ^recent_messages_query())
    |> Repo.all()
  end

  # Most recent `@default_page_size` messages per conversation, oldest-first.
  # A window-ranked subquery keeps the preload bounded even for long threads.
  defp recent_messages_query do
    ranked =
      from m in Message,
        select: %{
          id: m.id,
          row:
            over(row_number(),
              partition_by: m.conversation_id,
              order_by: [desc: m.inserted_at, desc: m.id]
            )
        }

    recent_ids =
      from r in subquery(ranked), where: r.row <= @default_page_size, select: r.id

    from m in Message,
      where: m.id in subquery(recent_ids),
      order_by: [asc: m.inserted_at, asc: m.id]
  end

  @doc "Fetches a conversation by id within the scope's active account."
  def get_conversation!(scope, id) do
    Conversation
    |> where([c], c.account_id == ^scope.active_account_id)
    |> Repo.get!(id)
  end

  @doc """
  Account-initiated: opens (or reuses) a conversation with a user identified by
  email on the scope's active project, and posts the operator's first message.
  """
  def start_conversation(scope, end_user_email, body) do
    {:ok, conversation} =
      find_or_create_conversation(scope.active_account_id, scope.active_project_id, end_user_email)

    {:ok, _message} = add_message(conversation, :operator, body, operator_sender_id(scope))
    {:ok, conversation}
  end

  @doc "Operator reply into an existing conversation in the scope's active account."
  def reply(scope, conversation_id, body) do
    conversation = get_conversation!(scope, conversation_id)
    add_message(conversation, :operator, body, operator_sender_id(scope))
  end

  defp operator_sender_id(scope), do: scope.user && to_string(scope.user.id)

  # ---- internals ----

  defp touch(%Conversation{} = conversation) do
    from(c in Conversation, where: c.id == ^conversation.id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  defp broadcast_new_message(%Conversation{} = conversation, %Message{} = message) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      conversation_topic(conversation.id),
      {:new_message, message}
    )

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      inbox_topic(conversation.account_id),
      {:inbox_updated, conversation.id}
    )
  end
end
