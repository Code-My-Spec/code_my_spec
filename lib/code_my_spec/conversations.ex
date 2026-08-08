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

  A third kind of conversation — the background-agent session, keyed by harness
  `session_external_id` instead of an end-user — has no human on the other end.
  `get_agent_conversation/2` and `AgentConversationLive` read it; it never
  surfaces through the operator-side inbox functions above.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.Mailbox
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

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
          {:ok, conversation} ->
            {:ok, conversation}

          # Lost an insert race — fetch the now-existing row.
          {:error, _changeset} ->
            {:ok, get_conversation_by_email!(account_id, project_id, end_user_email)}
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

  # ---- Background-agent side (harness session, no end user) ----

  @doc """
  Finds the conversation for a background-agent session — keyed by the harness
  `session_external_id` (the shared id for the whole Pi team) — or creates it.
  Agent conversations have no end user; the whole team's transcript lands here.
  """
  def find_or_create_agent_conversation(account_id, project_id, session_external_id) do
    case Repo.get_by(Conversation,
           account_id: account_id,
           project_id: project_id,
           session_external_id: session_external_id
         ) do
      nil ->
        %Conversation{}
        |> Conversation.agent_changeset(%{
          account_id: account_id,
          project_id: project_id,
          session_external_id: session_external_id
        })
        |> Repo.insert()
        |> case do
          {:ok, conversation} ->
            {:ok, conversation}

          # Lost an insert race — fetch the now-existing row.
          {:error, _changeset} ->
            {:ok,
             Repo.get_by!(Conversation,
               account_id: account_id,
               project_id: project_id,
               session_external_id: session_external_id
             )}
        end

      conversation ->
        {:ok, conversation}
    end
  end

  @doc """
  Appends a background-agent transcript line and broadcasts it like any other
  message (so the operator inbox renders it live). `kind` is the harness message
  kind (`"assistant"` / `"tool"` / `"status"`); `agent_role` is the speaking lane.
  """
  def add_agent_message(%Conversation{} = conversation, agent_role, kind, text) do
    %Message{}
    |> Message.agent_changeset(%{
      conversation_id: conversation.id,
      role: agent_message_role(kind),
      agent_role: agent_role,
      content: parts_for(text),
      sender_id: "agent:#{agent_role}"
    })
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        touch(conversation, false)
        broadcast_new_message(conversation, message)
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Records a call the model made, before it has returned.

  Written as its own turn so the call is visible while it runs rather than
  after — a conversation that goes quiet mid-tool reads as broken.
  """
  def add_tool_call(%Conversation{} = conversation, call_id, name, arguments) do
    agent_turn(conversation, %{
      role: :assistant,
      agent_role: "product",
      content: [],
      tool_calls: [%{"id" => call_id, "name" => name, "arguments" => arguments}],
      sender_id: "agent:product"
    })
  end

  @doc "Records what a call returned, paired to it by `call_id`."
  def add_tool_result(%Conversation{} = conversation, call_id, name, text) do
    agent_turn(conversation, %{
      role: :tool,
      agent_role: "product",
      content: [Message.text_part(text)],
      tool_call_id: call_id,
      sender_id: "agent:#{name}"
    })
  end

  @doc """
  Ends the conversation early because the model would not stop.

  A silent stop is indistinguishable from a hang, so this is a turn the reader
  can see, not a flag only the server knows about.
  """
  def halt(%Conversation{} = conversation, reason) do
    system_turn(conversation, "halted", "Stopped: #{reason}")
  end

  @doc "Ends the conversation because something failed. Everything already said stays."
  def fail(%Conversation{} = conversation, reason) do
    system_turn(conversation, "failed", "Failed: #{reason}")
  end

  # A model that would not stop and a provider that fell over are different
  # events. Writing both as one turn made them indistinguishable to a reader
  # and to a test — which is why nothing caught it.
  defp system_turn(conversation, kind, text) do
    agent_turn(conversation, %{
      role: :assistant,
      agent_role: kind,
      content: [Message.text_part(text)],
      sender_id: "agent:#{kind}"
    })
  end

  defp agent_turn(conversation, attrs) do
    %Message{}
    |> Message.agent_changeset(Map.put(attrs, :conversation_id, conversation.id))
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        touch(conversation, false)
        broadcast_new_message(conversation, message)
        {:ok, message}

      error ->
        error
    end
  end

  # An empty body contributes no part — an attachment-only message must not
  # gain a blank text part it never had.
  defp parts_for(nil), do: []
  defp parts_for(""), do: []
  defp parts_for(text), do: [Message.text_part(text)]

  # Harness kind -> Message role. Tool calls render distinctly; everything else
  # (assistant prose, status lines) is assistant-voiced.
  defp agent_message_role("tool"), do: :tool
  defp agent_message_role("user"), do: :user
  defp agent_message_role(_kind), do: :assistant

  @doc """
  Appends a message to a conversation and broadcasts it on the per-conversation
  topic (for connected widgets) and the account inbox topic (for the operator).
  """
  def add_message(%Conversation{} = conversation, role, body, sender_id \\ nil, attachments \\ []) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      role: role,
      # Text and files are both parts now. Callers still pass them separately
      # because that is how the widget and the operator form send them; the
      # split stops at this boundary.
      content: parts_for(body) ++ Enum.map(attachments, &%{"type" => "file", "file" => &1}),
      sender_id: sender_id
    })
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        touch(conversation, read_after(role))
        broadcast_new_message(conversation, message)
        {:ok, message}

      error ->
        error
    end
  end

  # An operator's own message leaves the thread read for the account; an
  # end-user (or assistant) message marks it unread so the inbox surfaces it.
  defp read_after(:operator), do: true
  defp read_after(_role), do: false

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
  Fetch a message by id within the scope's active account (via its
  conversation), with the conversation preloaded. `nil` if it isn't the
  account's. Used to serve a message's attachment to the operator.
  """
  def get_message(%Scope{} = scope, message_id) do
    Repo.one(
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.id == ^message_id and c.account_id == ^scope.active_account_id,
        preload: [conversation: c]
    )
  end

  @doc """
  Account-initiated: opens (or reuses) a conversation with a user identified by
  email on the scope's active project, and posts the operator's first message.
  """
  def start_conversation(scope, end_user_email, body) do
    {:ok, conversation} =
      find_or_create_conversation(
        scope.active_account_id,
        scope.active_project_id,
        end_user_email
      )

    {:ok, _message} = add_message(conversation, :operator, body, operator_sender_id(scope))
    {:ok, conversation}
  end

  @doc "Operator reply into an existing conversation in the scope's active account."
  def reply(scope, conversation_id, body, attachments \\ []) do
    conversation = get_conversation!(scope, conversation_id)
    add_message(conversation, :operator, body, operator_sender_id(scope), attachments)
  end

  @doc """
  Marks a conversation read for the account (a teammate opened it). Idempotent;
  broadcasts an inbox update so every teammate's inbox clears the unread mark.
  """
  def mark_read(%Scope{} = scope, conversation_id) do
    conversation = get_conversation!(scope, conversation_id)

    if conversation.read do
      {:ok, conversation}
    else
      {1, _} =
        from(c in Conversation, where: c.id == ^conversation.id)
        |> Repo.update_all(set: [read: true])

      broadcast_inbox_updated(conversation)
      {:ok, %{conversation | read: true}}
    end
  end

  @doc "Set a conversation's triage status (`:open` / `:closed`)."
  def set_status(%Scope{} = scope, conversation_id, status) when status in [:open, :closed] do
    conversation = get_conversation!(scope, conversation_id)

    with {:ok, updated} <-
           conversation |> Conversation.changeset(%{status: status}) |> Repo.update() do
      broadcast_inbox_updated(updated)
      {:ok, updated}
    end
  end

  @doc "Count of unread conversations for the scope's active account."
  def unread_count(%Scope{} = scope) do
    Repo.aggregate(
      from(c in Conversation,
        where: c.account_id == ^scope.active_account_id and c.read == false
      ),
      :count
    )
  end

  @doc """
  Email an offline end-user that a teammate replied, so a message sent while
  they're away isn't only seen on their next visit. Sent from the project's own
  mailbox (its verified domain) via `CodeMySpec.Mail`, so it's branded as the
  project — not CodeMySpec. Best-effort: no mailbox (the project hasn't set up
  Mail) simply skips, and delivery never blocks the reply.

  The caller (the operator inbox) decides "offline" from presence and only calls
  this when the user isn't connected.
  """
  def notify_offline_reply(%Conversation{} = conversation, body) when is_binary(body) do
    case Mail.catch_all_mailbox(conversation.project_id) do
      %Mailbox{} = mailbox ->
        Mail.send_outbound(mailbox, %{
          to: conversation.end_user_email,
          subject: "You have a new reply",
          body: body <> "\n\n— Reply by returning to the app."
        })

        :ok

      nil ->
        :skip
    end
  end

  @doc """
  The project's sprite-agent conversation — the accumulating record of every
  background-agent turn taken while working the project. `nil` until the first
  turn has been recorded.

  Read by `AgentConversationLive`, deliberately outside `list_conversations/1`
  and `unread_count/1` — a machine being watched is not a support thread, and
  must never raise the inbox's unread badge or appear in its list.
  """
  @spec get_agent_conversation(Scope.t(), Ecto.UUID.t()) :: Conversation.t() | nil
  def get_agent_conversation(%Scope{} = scope, project_id) do
    Conversation
    |> where([c], c.account_id == ^scope.active_account_id and c.project_id == ^project_id)
    |> where([c], not is_nil(c.session_external_id))
    |> order_by([c], desc: c.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp operator_sender_id(scope), do: scope.user && to_string(scope.user.id)

  # ---- internals ----

  defp touch(%Conversation{} = conversation, read) do
    from(c in Conversation, where: c.id == ^conversation.id)
    |> Repo.update_all(
      set: [read: read, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
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

  defp broadcast_inbox_updated(%Conversation{} = conversation) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      inbox_topic(conversation.account_id),
      {:inbox_updated, conversation.id}
    )
  end
end
