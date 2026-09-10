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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Mail,
      CodeMySpec.Repo,
      CodeMySpec.Users
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
  pushing under its own id before anything adopted it, and the story interview,
  which is not an agent in any sense and only borrowed the shape.

  This is what `find_or_create_agent_conversation/3` used to be for everything.
  Splitting them is the point — one caller has an agent and the other does not,
  and a single function had to pretend they were the same question.
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
          name: generated_name()
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

  Keyed on the agent. It was keyed on `session_external_id` — `pi:<root>` — so
  every agent on one working copy found the same row and the whole team's
  transcript landed there. That was deliberate and it stopped serving: a copy
  runs several lanes, their turns interleave into one thread, and a reply cannot
  say which of them spoke.

  A Claude Code lane arrives with an external id and no agent row of its own, so
  `find_or_create_session_conversation/3` still answers that question under its
  own name. Two callers, two questions, neither pretending to be the other.
  """
  def find_or_create_agent_conversation(account_id, project_id, agent_id) do
    case Repo.get_by(Conversation, agent_id: agent_id) do
      nil ->
        %Conversation{}
        |> Conversation.agent_changeset(%{
          account_id: account_id,
          project_id: project_id,
          agent_id: agent_id,
          name: generated_name()
        })
        |> Repo.insert()
        |> case do
          {:ok, conversation} ->
            {:ok, conversation}

          # Lost an insert race — fetch the now-existing row.
          {:error, _changeset} ->
            {:ok, Repo.get_by!(Conversation, agent_id: agent_id)}
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
  # A message with nothing in it is not a message.
  #
  # `parts_for/1` answers `[]` for `nil` and for `""`, so a caller with no text
  # inserted a row whose entire content was an empty list — and it renders as
  # the agent having spoken and said nothing.
  #
  # Guarded here rather than at each caller, which is the third attempt at this
  # and the first one that can be right. I guarded `write_turn_event/3` for a
  # missing key, then for a `nil` text, and empty rows kept arriving from a
  # caller I had not found: 47 on one coding agent in eight minutes, stamped
  # `agent:coding`, after two commits that were each supposed to have ended
  # them. Whichever caller it is, it cannot write one now.
  #
  # The cost of those rows was a day of misdiagnosis. A coding agent showing 99
  # empty messages against 0 substantive ones reads as a model returning
  # nothing, and I went through a credential rotation, a provider switch and
  # Alloy's response parsing looking for a fault that was never there.
  #
  # `{:ok, nil}` rather than an error: a caller with nothing to say has not done
  # anything wrong, and every one of them ignores the message it gets back.
  # Judged by what it renders to, not by what it looks like.
  #
  # Guarding the input shape was a search, and I ran it three times: `nil`, then
  # `""`, then a blank binary, and empty rows kept arriving — because the
  # harness sends a turn's content as a list of blocks and a turn that produced
  # none sends `[]`. Not nil, not a binary, straight past every guard and into a
  # row whose content is empty for a fourth reason.
  #
  # `parts_for/1` is the only thing that knows what a message will actually
  # contain. Ask it once, refuse when it has nothing, and there is no fifth
  # shape left to discover.
  #
  # What those rows cost: a coding agent showing 99 empty messages against 0
  # substantive ones reads as a model returning nothing, and I spent a day
  # inside a credential rotation, a provider switch and Alloy's response parsing
  # looking for a fault that was never there.
  #
  # `{:ok, nil}` rather than an error — a caller with nothing to say has not
  # done anything wrong, and every one of them ignores what it gets back.
  def add_agent_message(%Conversation{} = conversation, agent_role, kind, text) do
    if said_nothing?(text) do
      {:ok, nil}
    else
      do_add_agent_message(conversation, agent_role, kind, parts_for(text))
    end
  end

  # Whether anything was said, which is a different question from what to store.
  #
  # Trimming decides; it does not edit. The first cut of this stored the trimmed
  # text and a 17 kB transcript came back one byte short — the record has to be
  # what the model actually received, which is the whole argument for keeping a
  # wall of prose rather than truncating it.
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
  chat, which has only one; a harness transcript passes the real lane, because
  a sub-agent's call showing as the parent's is a wrong attribution and there
  is a criterion about it (8172).
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

  `failed?` is the provider's `is_error`, kept as data. The recorder used to
  fold it into the text as a `"← failed: "` prefix and the view read it back by
  matching that string; a boolean means the view asks a field.
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

  @doc """
  Record something the orchestrator did to an agent, on that agent's own thread.

  Story 985. The transcript recorded what the *agent* did and nothing the
  harness did to it, so a conversation that changed direction between one turn
  and the next had no explanation in it — the reason lived in a log on another
  machine.

  `what` is the sentence somebody reads. `count` and `tool` are the other two
  thirds of the rule John settled: say what happened, how much of it there is,
  and which tool answers for the rest. Both optional, because not every action
  has a quantity — handing over a requirement has none.

  A tool *name* rather than a link, deliberately. Half the readers of an agent's
  transcript are agents, and an agent cannot follow a link; what it can do is
  call the thing it is told about.

  Carried as typed parts rather than baked into the sentence so the view renders
  them distinctly and a reader — human or otherwise — is not parsing prose for
  a number.

  Silent when the agent has no conversation. An orchestrator acting on an agent
  nobody is watching is not an error, and refusing here would make recording an
  action able to fail the action itself.
  """
  @spec record_orchestrator_action(Agent.t() | nil, String.t(), keyword()) ::
          {:ok, Message.t()} | :ok
  def record_orchestrator_action(agent, what, opts \\ [])

  def record_orchestrator_action(nil, _what, _opts), do: :ok

  def record_orchestrator_action(%{id: agent_id}, what, opts) when is_binary(what) do
    case Repo.get_by(Conversation, agent_id: agent_id) do
      nil ->
        :ok

      conversation ->
        agent_turn(conversation, %{
          role: :orchestrator,
          content: orchestrator_parts(what, opts)
        })
    end
  end

  # By id as well as by struct: most call sites hold one or the other, and a
  # lookup at every one of them is a lookup that can be forgotten at one of them.
  def record_orchestrator_action(agent_id, what, opts) when is_binary(agent_id) do
    record_orchestrator_action(%{id: agent_id}, what, opts)
  end

  def record_orchestrator_action(_agent, _what, _opts), do: :ok

  defp orchestrator_parts(what, opts) do
    [%{"type" => "text", "text" => what}]
    |> maybe_part("count", opts[:count])
    |> maybe_part("tool", opts[:tool])
    |> maybe_part("kind", opts[:kind])
  end

  defp maybe_part(parts, _type, nil), do: parts
  defp maybe_part(parts, _type, ""), do: parts

  defp maybe_part(parts, type, value),
    do: parts ++ [%{"type" => type, "text" => to_string(value)}]

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
      # Only an operator message aimed at an agent carries these; everything
      # else leaves them nil, which is the honest answer to a question that
      # does not apply.
      delivery: Keyword.get(opts, :delivery),
      delivery_ref: Keyword.get(opts, :delivery_ref),
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
  Move a message from waiting to settled, and say so on the topic.

  Broadcast rather than left for the next render: a page still offering to take
  back something the agent is already acting on is the failure the ref exists
  to prevent, and it cannot know without being told.
  """
  @spec set_delivery(Message.t(), :delivered | :withdrawn) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def set_delivery(%Message{} = message, delivery)
      when delivery in [:delivered, :withdrawn] do
    message
    |> Ecto.Changeset.change(delivery: delivery)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          CodeMySpec.PubSub,
          conversation_topic(updated.conversation_id),
          {:message_updated, updated}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  The message waiting on `ref`, if it is still waiting.

  Scoped to `:pending` deliberately. A ref that names a message the agent
  already has must not be findable here, or a withdrawal would clear a row the
  agent is acting on and the transcript would disagree with the agent.
  """
  @spec pending_message_by_ref(String.t()) :: Message.t() | nil
  def pending_message_by_ref(ref) when is_binary(ref) do
    Repo.get_by(Message, delivery_ref: ref, delivery: :pending)
  end

  @doc """
  What this conversation is still waiting to deliver, oldest first.

  Read rather than held in a view's assigns: a person who reloads the page has
  not stopped waiting, and a pending message that vanished on refresh reads as
  one that was never accepted.
  """
  @spec pending_messages(Conversation.t()) :: [Message.t()]
  def pending_messages(%Conversation{} = conversation) do
    Message
    |> where([m], m.conversation_id == ^conversation.id and m.delivery == :pending)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
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

  Counted in the database rather than by listing, because the caller wants a
  number and `list_messages/2` is paged — a count taken from a page is the page
  size once the conversation is longer than one, and the one caller that needs
  this is a spending limit, which must not quietly stop counting at 50.
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

  Exists for the recorder's repeat check. Consecutive model turns often carry
  an identical last request message — an injected system reminder is the usual
  one — and writing it every time put the same block on screen twice.

  Scoped to a role, because a turn writes several rows: results, then the
  request's free text, then the response, then the calls. Compared against the
  most recent message of *any* role, a request is always being measured against
  the previous turn's response, so it never matches and every repeat is written.
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
  Everything a restarted agent needs to carry on, in the order it was said.

  The whole conversation while it is short enough, and from the last checkpoint
  onward once it is not: the summary compaction wrote, plus every message since,
  verbatim. That is the same shape a running agent holds after it compacts, so
  coming back lands it where it was rather than at the top.

  ## Said, not done

  Text turns only. An assistant's tool calls and their results are its working,
  and replaying those is worse than dropping them: a result describes a file at
  a path, and by the time an agent is being resumed the checkout may be a
  different one — story 963 moves the main agent between checkouts on purpose.
  Alloy's own compaction clears old tool results for the same reason.
  """
  @spec resume_messages(Conversation.t()) :: [map()]
  def resume_messages(%Conversation{} = conversation) do
    case latest_checkpoint(conversation) do
      nil -> conversation |> all_messages() |> Enum.flat_map(&as_turn/1)
      checkpoint -> checkpoint.messages ++ tail_after(conversation, checkpoint)
    end
  end

  @doc """
  Write down what an agent's compaction decided to keep.

  Called when the machine reports a compaction, so the summary the agent is now
  running on is the summary a restart resumes from. Deriving a second one here
  would be a different reading of the same conversation, and the one nobody read
  is the one that would survive.
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
  # By the anchor row's timestamp when there is one. When there is not — the row
  # was deleted, and the reference nullifies rather than cascades — the
  # checkpoint's own `inserted_at` is the cut. Not "replay everything": that
  # would hand the model the summary *and* the conversation it summarises, which
  # is the one outcome worse than losing the anchor.
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
    |> Enum.flat_map(&as_turn/1)
  end

  # Unpaginated on purpose. `list_messages/2` answers what a page renders and
  # caps at a page size; this answers what an agent knows, and a cap
  # here would silently be the difference between an agent that remembers
  # yesterday and one that does not.
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

  # One transcript row as one turn, or nothing.
  #
  # A list rather than a value so a row with no text drops out instead of
  # becoming an empty turn: providers reject empty content, and an agent that
  # cannot be resumed because somebody sent a blank line is a failure with no
  # visible cause.
  defp as_turn(%Message{} = message) do
    case {turn_role(message.role), Message.text(message)} do
      {nil, _text} -> []
      {_role, ""} -> []
      {role, text} -> [%{"role" => role, "content" => text}]
    end
  end

  # Alloy speaks two roles. An operator and an end user are both "the human" to
  # a model, and a `:tool` row is the working this deliberately leaves out.
  defp turn_role(:assistant), do: "assistant"
  defp turn_role(role) when role in [:user, :operator], do: "user"
  defp turn_role(_role), do: nil

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
    # Support only. An inbox is for "someone needs you", and a machine's
    # conversation in it costs the surface the only meaning it has — story 870's
    # rule, which said so and was not enforced anywhere: this filtered on the
    # account and nothing else, so every agent conversation was listed.
    #
    # Agent conversations are reachable from their own project surface. This is
    # the query the support inbox reads, so it is where the separation belongs.
    Conversation
    |> where([c], c.account_id == ^scope.active_account_id and c.type == :support)
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

  @doc """
  End-user messages that reached the scope's active project through a widget,
  newest first.

  Support threads only, and `:user` turns only: the operator's replies travel
  the other way, and an agent transcript never came through a widget at all.
  Provisioning's widget step reads this to answer "has anything actually
  arrived", which is a question about inbound traffic — counting our own
  outbound replies would let a project prove its widget works by us talking to
  it.
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
    # Either key. An agent's own thread names the agent; a Claude Code lane's
    # names the session. What both mean is "this belongs to something that was
    # running", which is what separates it from a support thread.
    |> where([c], not is_nil(c.agent_id) or not is_nil(c.session_external_id))
    |> order_by([c], desc: c.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every agent conversation on a project, newest activity first, each with how
  many turns it holds and when it last moved.

  The counterpart to `get_agent_conversation/2`, which answers "the newest one"
  — fine when a project had one agent, and silently hiding four when it has
  five.

  Counted in the same query rather than per row: five conversations is five
  extra round trips today and one per agent forever after, for a number that
  is only ever shown next to the name.
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

    # The agent's checkout comes along because it is what tells two rows apart.
    #
    # The row's second line used to be `session_external_id`, which read
    # `pi:<path>` and carried the path by accident. Keying the conversation on
    # the agent emptied that column for every agent thread, so the line rendered
    # blank — the page lost the one fact that distinguishes three copies of the
    # same project, which is the complaint (18f50c87) that put the path in the
    # key to begin with.
    #
    # A left join, because a Claude Code lane has an external id and no agent
    # row, and still needs its line.
    from(c in Conversation,
      left_join: n in subquery(counts),
      on: n.conversation_id == c.id,
      left_join: a in Agent,
      on: a.id == c.agent_id,
      where: c.account_id == ^scope.active_account_id and c.project_id == ^project_id,
      where: c.type == :agent,
      where: not is_nil(c.agent_id) or not is_nil(c.session_external_id),
      order_by: [desc: c.updated_at],
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
  Rename a conversation.

  Scoped, because the id comes off a URL: without the account check any
  conversation id renames any conversation.
  """
  @spec rename_conversation(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename_conversation(%Scope{} = scope, conversation_id, name) do
    Conversation
    |> where([c], c.id == ^conversation_id and c.account_id == ^scope.active_account_id)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation
        |> Conversation.rename_changeset(%{name: name})
        |> Repo.update()
    end
  end

  @doc """
  Get one agent conversation by id, scoped to the account.

  The show page takes its id from the URL, so this is the check that one
  account's transcript is not readable by another.
  """
  @spec get_agent_conversation_by_id(Scope.t(), Ecto.UUID.t()) :: Conversation.t() | nil
  def get_agent_conversation_by_id(%Scope{} = scope, conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id and c.account_id == ^scope.active_account_id)
    |> where([c], c.type == :agent)
    |> Repo.one()
  end

  # A name so a new conversation is never nameless — an index of five UUIDs is
  # the problem this exists to avoid, and it appears before anyone has had the
  # chance to name anything.
  #
  # Random rather than derived from the session id: it is stored and editable,
  # so it does not need to be reproducible, and a derived name would silently
  # change if the derivation ever did.
  @adjectives ~w(amber brisk candid dusk eager fleet grave hollow iron jade
                 keen lucid mellow north opal patient quiet russet slate tacit
                 umber vivid warm yonder zinc)
  @nouns ~w(anvil badger cairn drift ember fathom gable harbor inlet juniper
            kestrel lantern meadow nimbus orchard pillar quarry ridge summit
            thicket vale willow yarrow)

  defp generated_name do
    "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}"
  end

  @doc """
  What to show for a conversation that has no name — rows created before names
  existed, which are not worth backfilling with a name nobody chose.

  The session id, shortened. It is the identity anyway, and it is what appears
  in the logs you would go read next.
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
