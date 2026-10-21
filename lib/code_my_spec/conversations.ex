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

  A third kind — `type: :agent`, keyed on the agent (or, for a Claude Code lane
  no agent row adopted, on its `session_external_id`) — has no human on the
  other end. `AgentConversationLive` reads it; it never surfaces through the
  operator-side inbox functions above.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Mail,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Conversations.Checkpoint
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

  @doc "Listen to one conversation's messages."
  def subscribe_conversation(conversation_id),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, conversation_topic(conversation_id))

  @doc """
  Stop listening to one conversation's messages.

  A reader can move between conversations without its process ending (the
  agent cockpit patches from one to the next); without this one agent's turns
  arrive in another's transcript.
  """
  def unsubscribe_conversation(conversation_id),
    do: Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, conversation_topic(conversation_id))

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
  Finds a conversation keyed by an external session id, or creates it.

  For the threads under `type: :agent` that have no agent: a Claude Code lane
  pushing under its own id before anything adopted it, and the story interview.
  """
  def find_or_create_session_conversation(account_id, project_id, session_external_id) do
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
          session_external_id: session_external_id,
          name: generated_name(account_id, project_id)
        })
        |> Repo.insert()
        |> case do
          {:ok, conversation} ->
            {:ok, conversation}

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
  Finds an agent's conversation, or creates it.

  Keyed on the agent, never on the working copy: a copy runs several agents,
  and one thread per copy interleaved their turns.

  The one exception: a project born from guided intake already has a
  conversation keyed `"intake:<plan id>"` (`Intake.convert/2`). The first agent
  the project gets adopts that row, so the interview and the agent's turns read
  as one thread. Only the `"intake:"` prefix is adopted, never any unclaimed
  session row.
  """
  def find_or_create_agent_conversation(account_id, project_id, agent_id) do
    case Repo.get_by(Conversation, agent_id: agent_id) do
      nil ->
        case adopt_intake_conversation(project_id, agent_id) do
          {:ok, conversation} -> {:ok, conversation}
          :none -> create_agent_conversation(account_id, project_id, agent_id)
        end

      conversation ->
        {:ok, conversation}
    end
  end

  defp create_agent_conversation(account_id, project_id, agent_id) do
    %Conversation{}
    |> Conversation.agent_changeset(%{
      account_id: account_id,
      project_id: project_id,
      agent_id: agent_id,
      name: generated_name(account_id, project_id)
    })
    |> Repo.insert()
    |> case do
      {:ok, conversation} ->
        {:ok, conversation}

      # Lost an insert race — fetch the now-existing row.
      {:error, _changeset} ->
        {:ok, Repo.get_by!(Conversation, agent_id: agent_id)}
    end
  end

  defp adopt_intake_conversation(project_id, agent_id) do
    query =
      from c in Conversation,
        where:
          c.project_id == ^project_id and is_nil(c.agent_id) and
            like(c.session_external_id, "intake:%"),
        limit: 1

    case Repo.one(query) do
      nil ->
        :none

      conversation ->
        conversation
        |> Conversation.agent_changeset(%{agent_id: agent_id})
        |> Repo.update()
    end
  end

  @doc """
  Appends a background-agent transcript line and broadcasts it like any other
  message (so the operator inbox renders it live). `kind` is the harness message
  kind (`"assistant"` / `"tool"` / `"status"`); `agent_role` is the speaking lane.
  """
  # A message with nothing in it is not written (`{:ok, nil}`): empty rows read
  # as a model returning nothing. Guarded here, for every caller, and judged by
  # what it renders to (`parts_for/1`), not by input shape.
  # See knowledge/agents/coordination, "Conversations".
  def add_agent_message(%Conversation{} = conversation, agent_role, kind, text) do
    if said_nothing?(text) do
      {:ok, nil}
    else
      do_add_agent_message(conversation, agent_role, kind, parts_for(text))
    end
  end

  # Trimming decides whether anything was said; it never edits what is stored,
  # which must be what the model received.
  defp said_nothing?(nil), do: true
  defp said_nothing?([]), do: true
  defp said_nothing?(text) when is_binary(text), do: String.trim(text) == ""
  defp said_nothing?(other), do: parts_for(other) == []

  defp do_add_agent_message(%Conversation{} = conversation, agent_role, kind, parts) do
    %Message{}
    |> Message.agent_changeset(%{
      conversation_id: conversation.id,
      role: agent_message_role(kind),
      agent_role: agent_role,
      content: parts,
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

  `agent_role` is the speaking lane. It defaults to `"product"` for the in-app
  chat, which has only one; a harness transcript passes the real lane, so a
  sub-agent's call is not attributed to the parent.
  """
  def add_tool_call(
        %Conversation{} = conversation,
        call_id,
        name,
        arguments,
        agent_role \\ "product"
      ) do
    agent_turn(conversation, %{
      role: :assistant,
      agent_role: agent_role,
      content: [],
      tool_calls: [%{"id" => call_id, "name" => name, "arguments" => arguments}],
      sender_id: "agent:#{agent_role}"
    })
  end

  @doc """
  Records what a call returned, paired to it by `call_id`.

  `failed?` is the provider's `is_error`, kept as data (`tool_failed`).
  """
  def add_tool_result(
        %Conversation{} = conversation,
        call_id,
        name,
        text,
        opts \\ []
      ) do
    agent_turn(conversation, %{
      role: :tool,
      agent_role: Keyword.get(opts, :agent_role, "product"),
      content: [Message.text_part(text)],
      tool_call_id: call_id,
      tool_failed: Keyword.get(opts, :failed?, false),
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
  # events, written as different turns.
  defp system_turn(conversation, kind, text) do
    agent_turn(conversation, %{
      role: :assistant,
      agent_role: kind,
      content: [Message.text_part(text)],
      sender_id: "agent:#{kind}"
    })
  end

  @doc """
  Record a message that was sent to an agent, on that agent's conversation.

  For senders that do not record through `Agents.dispatch_message` themselves;
  without this the message reaches the agent and never appears in the
  transcript. Written as `:operator`, the role every line that reaches an
  agent uses (and that resume hands the model as "user").

  Silent when the agent has no conversation: recording must not fail the send.
  """
  @spec record_sent_to_agent(Agent.t() | String.t() | nil, String.t()) ::
          {:ok, Message.t()} | :ok
  def record_sent_to_agent(nil, _what), do: :ok

  def record_sent_to_agent(%{id: agent_id}, what) when is_binary(what) do
    case Repo.get_by(Conversation, agent_id: agent_id) do
      nil -> :ok
      conversation -> add_message(conversation, :operator, what, "operator")
    end
  end

  def record_sent_to_agent(agent_id, what) when is_binary(agent_id) and is_binary(what) do
    record_sent_to_agent(%{id: agent_id}, what)
  end

  def record_sent_to_agent(_agent, _what), do: :ok

  @doc "Record a completed restart independently of delivery of its notice."
  @spec record_restart(Agent.t(), String.t()) ::
          {:ok, Message.t()} | :ok | {:error, Ecto.Changeset.t()}
  def record_restart(%{id: agent_id}, reason) do
    case Repo.get_by(Conversation, agent_id: agent_id) do
      nil ->
        :ok

      conversation ->
        # An action record has no delivery state and is not an agent reply.
        # It must survive a failed notice without making the agent look alive.
        add_message(
          conversation,
          :operator,
          "Restart performed. Reason: #{reason}",
          "system:restart"
        )
    end
  end

  @doc "The tool calls on this agent's conversation since `since`, oldest first."
  @spec tool_calls_since(Ecto.UUID.t(), DateTime.t()) :: [
          %{name: String.t(), arguments: map(), at: DateTime.t()}
        ]
  def tool_calls_since(agent_id, %DateTime{} = since) when is_binary(agent_id) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> where([m, c], c.agent_id == ^agent_id and m.inserted_at >= ^since)
    |> where([m], not is_nil(m.tool_calls))
    |> order_by([m], asc: m.inserted_at)
    |> select([m], {m.inserted_at, m.tool_calls})
    |> Repo.all()
    |> Enum.flat_map(fn {at, calls} ->
      Enum.map(calls, &%{name: &1["name"] || "", arguments: &1["arguments"] || %{}, at: at})
    end)
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
  # An empty list of content blocks. The harness sends a turn's content this
  # way and a turn that produced none sends `[]` — not nil, not a binary,
  # straight past the other two guards.
  defp parts_for([]), do: []
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
  def add_message(
        %Conversation{} = conversation,
        role,
        body,
        sender_id \\ nil,
        attachments \\ [],
        opts \\ []
      ) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      role: role,
      origin: Keyword.get(opts, :origin),
      # Only an operator message aimed at an agent carries these.
      delivery: Keyword.get(opts, :delivery),
      delivery_ref: Keyword.get(opts, :delivery_ref),
      # Text and files are both parts; callers pass them separately.
      content: parts_for(body) ++ Enum.map(attachments, &%{"type" => "file", "file" => &1}),
      sender_id: sender_id
    })
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        touch(conversation, read_after(role))
        if Keyword.get(opts, :broadcast, true), do: broadcast_new_message(conversation, message)
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
  Move a message from waiting to settled, and say so on the topic.

  Broadcast so a page stops offering to take back a message the agent is
  already acting on.
  """
  @spec set_delivery(Message.t(), :delivered | :withdrawn | :failed) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def set_delivery(%Message{} = message, delivery, opts \\ [])
      when delivery in [:delivered, :withdrawn, :failed] do
    message
    |> Ecto.Changeset.change(delivery: delivery)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        if Keyword.get(opts, :broadcast, true) do
          Phoenix.PubSub.broadcast(
            CodeMySpec.PubSub,
            conversation_topic(updated.conversation_id),
            {:message_updated, updated}
          )
        end

        {:ok, updated}

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

  @doc """
  How many messages in `role` this conversation holds.

  Counted in the database: `list_messages/2` is paged, and the caller is a
  spending limit that must not stop counting at a page size.
  """
  @spec count_messages(Conversation.t(), atom() | String.t()) :: non_neg_integer()
  def count_messages(%Conversation{} = conversation, role) do
    role = to_string(role)

    Message
    |> where([m], m.conversation_id == ^conversation.id and m.role == ^role)
    |> Repo.aggregate(:count)
  end

  @doc """
  Text of the conversation's most recent message in `role`, or nil if none.

  For the recorder's repeat check (consecutive turns often carry an identical
  last request message). Scoped to a role because a turn writes several rows
  of different roles; compared against any role, nothing ever matches.
  """
  @spec last_message_text(Conversation.t(), atom()) :: String.t() | nil
  def last_message_text(%Conversation{} = conversation, role) do
    Message
    |> where([m], m.conversation_id == ^conversation.id and m.role == ^role)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      message -> Message.text(message)
    end
  end

  @doc """
  Text of the last thing said *to* the agent — by a person or the operator —
  or nil. What a failed turn was answering, so it can be asked again.
  """
  @spec last_request_text(Conversation.t()) :: String.t() | nil
  def last_request_text(%Conversation{} = conversation) do
    Message
    |> where([m], m.conversation_id == ^conversation.id and m.role in [:user, :operator])
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      message -> Message.text(message)
    end
  end

  @doc """
  `last_request_text/1` as it stood just before `message`: what a failed turn
  was answering, once the notice about it has been said since.
  """
  @spec request_before(Message.t()) :: String.t() | nil
  def request_before(%Message{conversation_id: conversation_id, inserted_at: at, id: id}) do
    Message
    |> where(
      [m],
      m.conversation_id == ^conversation_id and m.role in [:user, :operator] and
        m.inserted_at <= ^at and m.id != ^id
    )
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      message -> Message.text(message)
    end
  end

  @doc "Whether anything has been said to the agent since `message`."
  @spec request_since?(Message.t()) :: boolean()
  def request_since?(%Message{conversation_id: conversation_id, inserted_at: at, id: id}) do
    Message
    |> where(
      [m],
      m.conversation_id == ^conversation_id and m.role in [:user, :operator] and
        m.inserted_at >= ^at and m.id != ^id
    )
    |> Repo.exists?()
  end

  @doc """
  Everything a restarted agent needs to carry on, in the order it was said.

  The whole conversation while it is short enough, and from the last checkpoint
  onward once it is not: the summary compaction wrote, plus every message since,
  verbatim. That is the same shape a running agent holds after it compacts, so
  coming back lands it where it was rather than at the top.

  ## Done as well as said

  Everything the model had: an assistant's tool calls and what each returned,
  as well as what was said. A resumed agent that knows it made calls and not
  what they returned cannot carry on a turn, only restart it.

  A call with no recorded result — one the process died in the middle of, or
  one made before results were recorded — is answered with a result saying so.
  A provider refuses a call nobody answered, and the honest answer is that
  whether it took effect is unknown.
  """
  @spec resume_messages(Conversation.t()) :: [map()]
  def resume_messages(%Conversation{} = conversation) do
    case latest_checkpoint(conversation) do
      nil -> conversation |> all_messages() |> as_turns()
      checkpoint -> as_turns(checkpoint.messages, tail_after(conversation, checkpoint))
    end
  end

  @doc """
  Write down what an agent's compaction decided to keep.

  Called when the machine reports a compaction, so the summary the agent is now
  running on is the summary a restart resumes from; nothing derives a second.
  """
  @spec record_checkpoint(Conversation.t(), [map()], keyword()) ::
          {:ok, Checkpoint.t()} | {:error, Ecto.Changeset.t()}
  def record_checkpoint(%Conversation{} = conversation, messages, opts \\ []) do
    %Checkpoint{}
    |> Checkpoint.changeset(%{
      conversation_id: conversation.id,
      messages: messages,
      turn: Keyword.get(opts, :turn),
      through_message_id: Keyword.get(opts, :through_message_id) || last_message_id(conversation)
    })
    |> Repo.insert()
  end

  @doc "The most recent checkpoint on this conversation, or nil."
  @spec latest_checkpoint(Conversation.t()) :: Checkpoint.t() | nil
  def latest_checkpoint(%Conversation{} = conversation) do
    Checkpoint
    |> where([c], c.conversation_id == ^conversation.id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(1)
    |> Repo.one()
  end

  # Everything after the row the checkpoint stopped at.
  #
  # By the anchor row's timestamp, or the checkpoint's own `inserted_at` when the
  # anchor was deleted — never "replay everything", which would hand the model
  # the summary and what it summarises.
  defp tail_after(conversation, %Checkpoint{} = checkpoint) do
    cutoff =
      case checkpoint.through_message_id && Repo.get(Message, checkpoint.through_message_id) do
        %Message{inserted_at: at} -> at
        _ -> checkpoint.inserted_at
      end

    Message
    |> where([m], m.conversation_id == ^conversation.id and m.inserted_at > ^cutoff)
    |> order_by([m], asc: m.inserted_at, asc: m.id)
    |> Repo.all()
  end

  # Unpaginated on purpose: this is what an agent knows, not what a page renders.
  defp all_messages(%Conversation{} = conversation) do
    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> order_by([m], asc: m.inserted_at, asc: m.id)
    |> Repo.all()
  end

  defp last_message_id(%Conversation{} = conversation) do
    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> select([m], m.id)
    |> Repo.one()
  end

  # Transcript rows as the turns a model is handed, each call answered.
  #
  # A row is a turn, or nothing: a row with no text and no call drops out
  # rather than becoming an empty turn, which a provider rejects. Results are
  # not turns of their own; each goes straight after the assistant turn that
  # made its call, so a call and its answer stay adjacent however the rows
  # interleaved.
  #
  # A checkpoint's turns arrive already paired, as the agent held them.
  defp as_turns(checkpoint \\ [], rows) do
    results = for %Message{role: :tool, tool_call_id: id} = row <- rows, into: %{}, do: {id, row}

    turns = rows |> Enum.flat_map(&as_turn/1) |> Enum.flat_map(&answer_calls(&1, results))
    merge_adjacent(checkpoint ++ turns)
  end

  # A restart must not deliver queued messages through history or resurrect
  # messages that were withdrawn or failed delivery. Legacy rows have nil.
  defp as_turn(%Message{delivery: delivery}) when delivery in [:pending, :withdrawn, :failed],
    do: []

  defp as_turn(%Message{role: :tool}), do: []

  defp as_turn(%Message{role: :assistant, tool_calls: [_ | _] = calls} = message) do
    blocks =
      text_blocks(Message.text(message)) ++
        Enum.map(calls, fn call ->
          %{
            "type" => "tool_use",
            "id" => call["id"],
            "name" => call["name"],
            "input" => call["arguments"] || %{}
          }
        end)

    [%{"role" => "assistant", "content" => blocks}]
  end

  defp as_turn(%Message{} = message) do
    case {turn_role(message.role), Message.text(message)} do
      {nil, _text} -> []
      {_role, ""} -> []
      {role, text} -> [%{"role" => role, "content" => text}]
    end
  end

  # Alloy speaks two roles. An operator and an end user are both "the human" to
  # a model.
  defp turn_role(:assistant), do: "assistant"
  defp turn_role(role) when role in [:user, :operator], do: "user"
  defp turn_role(_role), do: nil

  defp text_blocks(""), do: []
  defp text_blocks(text), do: [%{"type" => "text", "text" => text}]

  defp answer_calls(%{"role" => "assistant", "content" => blocks} = turn, results)
       when is_list(blocks) do
    case for(%{"type" => "tool_use", "id" => id} <- blocks, do: id) do
      [] -> [turn]
      ids -> [turn, %{"role" => "user", "content" => Enum.map(ids, &result_block(&1, results))}]
    end
  end

  defp answer_calls(turn, _results), do: [turn]

  defp result_block(id, results) do
    case Map.fetch(results, id) do
      {:ok, row} ->
        %{"type" => "tool_result", "tool_use_id" => id, "content" => Message.text(row)}
        |> then(&if(row.tool_failed, do: Map.put(&1, "is_error", true), else: &1))

      :error ->
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" =>
            "No result was recorded for this call. It may not have finished, or it may " <>
              "have taken effect; check before repeating it."
        }
    end
  end

  # Two turns in a row from one side become one when either carries blocks:
  # a call's answer and the next thing said to the agent are one user turn.
  # Plain text turns stay as they were said.
  defp merge_adjacent(turns) do
    turns
    |> Enum.reduce([], fn
      %{"role" => role, "content" => content} = turn,
      [%{"role" => role, "content" => before} = previous | rest]
      when is_list(content) or is_list(before) ->
        [%{previous | "content" => blocks(previous) ++ blocks(turn)} | rest]

      turn, acc ->
        [turn | acc]
    end)
    |> Enum.reverse()
  end

  defp blocks(%{"content" => text}) when is_binary(text), do: text_blocks(text)
  defp blocks(%{"content" => blocks}) when is_list(blocks), do: blocks

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
    # Support only: an inbox is for "someone needs you"; agent conversations
    # have their own project surface. Latest message first; a thread with no
    # messages ranks by when it opened.
    Conversation
    |> join(:left, [c], l in subquery(last_message_at_query()), on: l.conversation_id == c.id)
    |> where([c], c.account_id == ^scope.active_account_id and c.type == :support)
    |> order_by([c, l], desc: coalesce(l.at, c.inserted_at), desc: c.id)
    |> preload([c], messages: ^recent_messages_query())
    |> Repo.all()
  end

  defp last_message_at_query do
    from m in Message,
      group_by: m.conversation_id,
      select: %{conversation_id: m.conversation_id, at: max(m.inserted_at)}
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

  @doc """
  End-user messages that reached the scope's active project through a widget,
  newest first.

  Support threads and `:user` turns only: provisioning's widget step reads this
  to answer "has anything actually arrived", a question about inbound traffic.
  """
  @spec list_widget_messages(Scope.t(), keyword()) :: [Message.t()]
  def list_widget_messages(%Scope{} = scope, opts \\ []) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: c.account_id == ^scope.active_account_id,
      where: c.project_id == ^scope.active_project_id,
      where: c.type == :support,
      where: m.role == :user,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^Keyword.get(opts, :limit, @default_page_size)
    )
    |> Repo.all()
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
  The project's most recently updated agent conversation, or `nil`. Outside
  `list_conversations/1` and `unread_count/1`: a machine being watched is not
  a support thread. `list_agent_conversations/2` lists them all.
  """
  @spec get_agent_conversation(Scope.t(), Ecto.UUID.t()) :: Conversation.t() | nil
  def get_agent_conversation(%Scope{} = scope, project_id) do
    Conversation
    |> where([c], c.account_id == ^scope.active_account_id and c.project_id == ^project_id)
    # Either key. An agent's own thread names the agent; a Claude Code lane's
    # names the session. What both mean is "this belongs to something that was
    # running", which is what separates it from a support thread.
    |> where([c], not is_nil(c.agent_id) or not is_nil(c.session_external_id))
    |> order_by([c], desc: c.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every agent conversation on a project, latest message first, each with how
  many turns it holds and when it last moved.

  Counts come from the same query, not a round trip per row.
  """
  @spec list_agent_conversations(Scope.t(), Ecto.UUID.t()) :: [map()]
  def list_agent_conversations(%Scope{} = scope, project_id) do
    counts =
      from(m in Message,
        group_by: m.conversation_id,
        select: %{
          conversation_id: m.conversation_id,
          count: count(m.id),
          last_at: max(m.inserted_at)
        }
      )

    # The agent's checkout comes along because it tells two rows apart. A left
    # join: a Claude Code lane has no agent row and still needs its line.
    from(c in Conversation,
      left_join: n in subquery(counts),
      on: n.conversation_id == c.id,
      left_join: a in Agent,
      on: a.id == c.agent_id,
      where: c.account_id == ^scope.active_account_id and c.project_id == ^project_id,
      where: c.type == :agent,
      where: not is_nil(c.agent_id) or not is_nil(c.session_external_id),
      # Latest message first, not `updated_at`: a rename bumps that too.
      order_by: [desc: coalesce(n.last_at, c.inserted_at), desc: c.id],
      select: %{
        conversation: c,
        message_count: coalesce(n.count, 0),
        last_message_at: n.last_at,
        working_copy: a.working_copy,
        role: a.role
      }
    )
    |> Repo.all()
  end

  @doc """
  Get one agent conversation by id, scoped to the account **and the project**.

  The show page takes its id from the URL, so this is the check that stops one
  transcript being readable from another's address.

  Account alone is one axis short: under one account, another project's URL
  would render this project's transcript.

  A scope with no project answers `nil` rather than raising (Ecto refuses to
  compare a column with `nil`).
  """
  @spec get_agent_conversation_by_id(Scope.t(), Ecto.UUID.t()) :: Conversation.t() | nil
  def get_agent_conversation_by_id(%Scope{active_project_id: nil}, _conversation_id), do: nil

  def get_agent_conversation_by_id(%Scope{} = scope, conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id and c.account_id == ^scope.active_account_id)
    |> where([c], c.project_id == ^scope.active_project_id)
    |> where([c], c.type == :agent)
    |> Repo.one()
  end

  @doc """
  Give an agent conversation a name a person chose.

  The name is a display handle; the key (agent or session id) is unchanged.
  Read through `get_agent_conversation_by_id/2` first, so the scope check is
  the show page's: account and project, and never a support conversation.
  """
  @spec rename_agent_conversation(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename_agent_conversation(%Scope{} = scope, conversation_id, name) do
    case get_agent_conversation_by_id(scope, conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation
        |> Conversation.rename_changeset(name)
        |> Repo.update()
    end
  end

  # A name so a new conversation is never nameless. Random: it is stored and
  # editable, so it need not be reproducible.
  @adjectives ~w(amber brisk candid dusk eager fleet grave hollow iron jade
                 keen lucid mellow north opal patient quiet russet slate tacit
                 umber vivid warm yonder zinc)
  @nouns ~w(anvil badger cairn drift ember fathom gable harbor inlet juniper
            kestrel lantern meadow nimbus orchard pillar quarry ridge summit
            thicket vale willow yarrow)

  # Unique within the project: a collision renders two identical links to
  # different transcripts. A handful of attempts (575 names), then a suffix.
  defp generated_name(account_id, project_id) do
    taken =
      from(c in Conversation,
        where: c.account_id == ^account_id and c.project_id == ^project_id,
        where: not is_nil(c.name),
        select: c.name
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.find_value(1..8, fn _ ->
      name = "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}"
      if MapSet.member?(taken, name), do: nil, else: name
    end) || "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}-#{unique_suffix()}"
  end

  defp unique_suffix, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc """
  What to show for a conversation that has no name: the session id,
  shortened, else "unnamed".
  """
  @spec display_name(Conversation.t()) :: String.t()
  def display_name(%Conversation{name: name}) when is_binary(name) and name != "", do: name

  def display_name(%Conversation{session_external_id: id}) when is_binary(id) do
    case String.split(id, "-") do
      [first | _] when byte_size(first) == 8 -> first
      _ -> id
    end
  end

  def display_name(%Conversation{}), do: "unnamed"

  defp operator_sender_id(scope), do: scope.user && to_string(scope.user.id)

  # ---- internals ----

  defp touch(%Conversation{} = conversation, read) do
    from(c in Conversation, where: c.id == ^conversation.id)
    |> Repo.update_all(set: [read: read, updated_at: DateTime.utc_now()])
  end

  @doc "Publish a newly committed message when its caller deferred broadcasting inside a transaction."
  def broadcast_new_message(%Conversation{} = conversation, %Message{} = message) do
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
