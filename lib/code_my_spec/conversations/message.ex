defmodule CodeMySpec.Conversations.Message do
  @moduledoc """
  A single message in a conversation, human or agent.

  `content` is a list of typed parts rather than a string, mirroring
  `ReqLLM.Message` — which is what the provider hands us, so an agent turn is
  stored as it arrived instead of being flattened on the way in. A human
  message is one `%{"type" => "text"}` part; a file shared through the widget
  is a `%{"type" => "file"}` part, which is what `attachments` already was
  before it had a name.

  `tool_calls` rides on an assistant turn, `tool_call_id` pairs a `:tool` turn
  back to the call it answers. Both are nil for human messages, which is the
  whole point of one model: the human case is the degenerate one, not a
  different table.

  Authorship stays `(role, sender_id)`, with `agent_role` naming the speaking
  lane on agent transcripts. Ordered by `inserted_at`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias CodeMySpec.Conversations.Conversation
  alias CodeMySpec.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  # `count` and `tool` belong to orchestrator actions: how much of a thing there
  # is, and the name of the tool that lists the rest. Typed parts rather than a
  # sentence, so the view renders them distinctly and no reader — person or
  # agent — is parsing prose for a number. Story 985.
  @part_types ~w(text image file thinking count tool kind)

  schema "conversation_messages" do
    # Typed parts, in order. See @part_types for what a part may be.
    field :content, {:array, :map}, default: []
    # `:orchestrator` was a fifth value here, for what was done *to* an agent
    # rather than by it. It is gone: `Chat.Runner.to_provider_message/1` never
    # passed it to the model, so everything wearing it was visible to the person
    # watching and to nobody else — and the reader story 985 built it for, an
    # agent reading its own transcript, was never built. What genuinely reaches
    # an agent is sent to it, and a sent message is `:operator`.
    field :role, Ecto.Enum, values: [:user, :operator, :assistant, :tool]
    field :sender_id, :string
    # The speaking lane for agent transcripts: manager / product / spec_writer
    # / coding / qa. nil for human (user/operator) messages.
    field :agent_role, :string
    # Calls this assistant turn made. nil on every other kind of turn.
    field :tool_calls, {:array, :map}
    # The call a :tool turn is answering.
    field :tool_call_id, :string
    # Whether that call came back an error. Anthropic sends `is_error` on the
    # `tool_result` block; keeping it as a boolean is what lets the view ask a
    # field instead of matching a `"← failed: "` prefix it hoped the recorder
    # wrote. Defaults false here rather than in the migration.
    field :tool_failed, :boolean, default: false
    # Where the widget that sent this was running, as its host app reported at
    # connect time. Provisioning's widget step gates on it: markup can be right
    # while the socket, credential or CORS is not, so "a message arrived" only
    # proves the widget works if it arrived from the deployed site rather than
    # from someone's laptop.
    field :origin, :string
    # Whether the agent this was sent at has it. nil for everything that is not
    # an operator message at an agent — a widget message has no delivery
    # question, it is already where it was going.
    field :delivery, Ecto.Enum, values: [:delivered, :pending, :withdrawn, :failed]
    # The sender's handle on it while it can still be taken back. Minted before
    # the message leaves and carried by the machine, so a withdrawal names the
    # message rather than describing it: two identical messages are
    # indistinguishable by text at exactly the moment it matters.
    field :delivery_ref, :string

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Text of every text part, joined. The preview the inbox and search want.

  Derived on read rather than stored: a denormalized copy of this drifts, and
  the copy that drifts is the one a human reads.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: parts}) do
    parts
    |> Enum.filter(&(part_type(&1) == "text"))
    |> Enum.map_join("\n", &(get(&1, "text") || ""))
  end

  @doc "The file parts, in order — what `attachments` used to hold."
  @spec files(t()) :: [map()]
  def files(%__MODULE__{content: parts}) do
    parts
    |> Enum.filter(&(part_type(&1) == "file"))
    |> Enum.map(&get(&1, "file"))
  end

  @doc """
  Whether the agent this was sent at actually has it.

  False while it waits and false once it is taken back, so a caller asking "did
  this reach the agent" cannot get a yes out of a message the agent has never
  seen. A message with no delivery question — anything that is not aimed at an
  agent — is not delivered to one either.
  """
  @spec delivered?(t()) :: boolean()
  def delivered?(%__MODULE__{delivery: delivery}), do: delivery == :delivered

  @doc "Builds a single text part — the shape of an ordinary human message."
  @spec text_part(String.t()) :: map()
  def text_part(text), do: %{"type" => "text", "text" => text}

  @doc """
  Every message belonging to any of `agent_ids`, in one query rather than one
  per agent.

  The performance page's intervention read (issue 844907e0): a
  `find_or_create` plus a `list_messages` per agent is a query per agent, and
  all of them are one read. `agent_id` lives on `conversations`, not on the
  message -- a conversation is the agent's, and `adopt_intake_conversation/2`
  moves one onto an agent by writing that column -- so this joins back through
  it, on the same column `find_or_create_agent_conversation/3` filters on. The
  row's own `agent_id` comes back with the message, because a caller asking
  for several agents has to know which one each message belongs to.

  `limit_per_agent` bounds each agent's share, as `list_messages/2`'s `limit`
  bounds one. A plain `limit` would bound the whole read instead and hand the
  first agent all of it.

  The pages that already have the conversations in hand filter on
  `conversation_id` directly (`by_conversations/2`); joining back through
  `conversations` to arrive at an id the caller knows is the query this module
  does not need to repeat, and on the 188-agent project the read is the slow
  half of the page either way (issue b118c546).
  """
  @spec by_agents([String.t()], keyword()) :: Ecto.Query.t()
  def by_agents(agent_ids, opts \\ []) do
    limit = Keyword.get(opts, :limit_per_agent)

    # A map rather than the struct: `agent_id` is the conversation's field, and
    # `select_merge` will not add a key the schema does not have -- it raises
    # `struct Message does not have the key :agent_id`, which is the same
    # mistake as `%{m | agent_id: c.agent_id}` one layer down.
    from m in __MODULE__,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: c.agent_id in ^agent_ids,
      order_by: [asc: c.agent_id, asc: m.inserted_at, asc: m.id],
      limit: ^limit,
      select: %{
        agent_id: c.agent_id,
        role: m.role,
        sender_id: m.sender_id,
        content: m.content,
        tool_failed: m.tool_failed,
        inserted_at: m.inserted_at
      }
  end

  @doc """
  Every message of `conversation_ids`, with the agent each belongs to.

  The same rows `by_agents/2` answers, for a caller that already knows the
  conversations -- the performance page reads every agent's id from one read
  and can join on `conversation_id` from there rather than asking the database
  to find the same conversations again (issue b118c546).

  The content is not selected: it is the bulk of a transcript, and every count
  the page takes is off `role`, `sender_id` and `tool_failed`. `content_of/1`
  reads the text back for the few rows whose text is actually reported.
  """
  @spec by_conversations([Ecto.UUID.t()], keyword()) :: Ecto.Query.t()
  def by_conversations(conversation_ids, opts \\ []) do
    limit = Keyword.get(opts, :limit_per_agent)

    from m in __MODULE__,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: m.conversation_id in ^conversation_ids,
      order_by: [asc: c.agent_id, asc: m.inserted_at, asc: m.id],
      limit: ^limit,
      select: %{
        id: m.id,
        conversation_id: m.conversation_id,
        role: m.role,
        sender_id: m.sender_id,
        tool_failed: m.tool_failed,
        inserted_at: m.inserted_at
      }
  end

  # An intervention's text alone: every other message's `content` is the bulk
  # of a transcript (10MB against 126,990 rows on the project this was measured
  # on, of which 5,473 are interventions) and nothing reads it.
  @intervention_senders ["operator", "system:restart"]

  @doc """
  The interventions among `conversation_ids`: the `:operator` messages whose
  sender says a person acted or a restart was performed, with their text.

  Narrower than `by_conversations/2` on both axes a transcript is large in --
  the sender, and `content` -- so the page's own nudge and restart counts are a
  read of a few thousand short rows rather than of every message of every
  agent, most of it assistant prose (issue b118c546).

  The order is `inserted_at` within an agent, which is what an intervention
  list is read in; callers group by `agent_id` themselves.
  """
  @spec interventions([Ecto.UUID.t()], keyword()) :: Ecto.Query.t()
  def interventions(conversation_ids, opts \\ []) do
    limit = Keyword.get(opts, :limit_per_agent)

    from m in __MODULE__,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: m.conversation_id in ^conversation_ids,
      where: m.role == :operator and m.sender_id in ^@intervention_senders,
      order_by: [asc: c.agent_id, asc: m.inserted_at, asc: m.id],
      limit: ^limit,
      select: %{
        id: m.id,
        conversation_id: m.conversation_id,
        role: m.role,
        sender_id: m.sender_id,
        content: m.content,
        inserted_at: m.inserted_at
      }
  end

  @doc "The text parts of each of `ids`, keyed by id, for the rows whose text is reported."
  @spec content_of([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [map()]}
  def content_of([]), do: %{}

  def content_of(ids) do
    from(m in __MODULE__, where: m.id in ^ids, select: {m.id, m.content})
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :content,
      :role,
      :sender_id,
      :conversation_id,
      :origin,
      :delivery,
      :delivery_ref
    ])
    |> validate_required([:role, :conversation_id])
    |> validate_parts()
    |> validate_carries_something()
  end

  @doc """
  Changeset for an agent turn: carries the speaking lane, and may hold tool
  calls or answer one.

  A turn with only tool calls and no content is legitimate — the
  carries-something rule does not apply, because the calls *are* the evidence.
  """
  def agent_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :content,
      :role,
      :agent_role,
      :sender_id,
      :conversation_id,
      :tool_calls,
      :tool_call_id,
      :tool_failed
    ])
    |> validate_required([:role, :conversation_id])
    |> validate_parts()
    |> name_an_empty_writer()
  end

  # Who wrote a message with nothing in it.
  #
  # I have guarded this four times — a missing `"text"` key, a `nil` text, a
  # blank binary, and finally the rendered parts — and empty rows kept arriving
  # from a caller I could not find by reading. Each guard was a guess about the
  # shape; none of them was a way to find the writer.
  #
  # So the row names it. One `Logger.warning` with the stack, only on the path
  # that should no longer happen, is worth more than a fifth guess: an empty
  # message renders as the agent having spoken and said nothing, and a coding
  # agent showing 99 of those against 0 real ones cost a day of looking inside a
  # provider for a fault that was never there.
  #
  # Not a validation. Refusing the insert would lose whatever else the row
  # carries, and the point is to learn where it comes from, not to drop it.
  defp name_an_empty_writer(changeset) do
    with [] <- get_field(changeset, :content),
         tool_calls when tool_calls in [nil, []] <- get_field(changeset, :tool_calls) do
      require Logger

      Logger.warning(
        "[Conversations] an empty message reached the changeset — " <>
          "role=#{inspect(get_field(changeset, :role))} " <>
          "sender=#{inspect(get_field(changeset, :sender_id))}\n" <>
          Exception.format_stacktrace()
      )

      changeset
    else
      _ -> changeset
    end
  end

  # Every part declares a type we know how to render. An unknown type would
  # reach a `case` in the view with no clause for it, at render time.
  defp validate_parts(changeset) do
    parts = get_field(changeset, :content) || []

    case Enum.reject(parts, &(part_type(&1) in @part_types)) do
      [] ->
        changeset

      bad ->
        add_error(
          changeset,
          :content,
          "unknown part type: #{inspect(Enum.map(bad, &part_type/1))}"
        )
    end
  end

  # A human message must say or carry something. Replaces the old
  # body-or-attachments rule, which was the same rule over the same two things.
  defp validate_carries_something(changeset) do
    case get_field(changeset, :content) || [] do
      [] -> add_error(changeset, :content, "can't be empty")
      _ -> changeset
    end
  end

  defp part_type(part), do: get(part, "type")

  # Parts arrive as string-keyed maps from the database and may arrive
  # atom-keyed from a caller building one inline.
  defp get(part, key) when is_map(part),
    do: Map.get(part, key) || Map.get(part, String.to_atom(key))

  defp get(_part, _key), do: nil
end
