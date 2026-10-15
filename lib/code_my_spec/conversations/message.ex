defmodule CodeMySpec.Conversations.Message do
  @moduledoc """
  A single message in a conversation, human or agent.

  `content` is a list of typed parts rather than a string, mirroring
  `ReqLLM.Message` — which is what the provider hands us, so an agent turn is
  stored as it arrived instead of being flattened on the way in. A human
  message is one `%{"type" => "text"}` part; a file shared through the widget
  is a `%{"type" => "file"}` part.

  `tool_calls` rides on an assistant turn, `tool_call_id` pairs a `:tool` turn
  back to the call it answers. Both are nil for human messages: the human case
  is the degenerate one, not a different table.

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
  # is, and the name of the tool that lists the rest. Typed parts, so no reader
  # parses prose for a number.
  @part_types ~w(text image file thinking count tool kind)

  schema "conversation_messages" do
    # Typed parts, in order. See @part_types for what a part may be.
    field :content, {:array, :map}, default: []
    # What reaches an agent is sent to it, as `:operator`; there is no role for
    # a line the model never sees.
    field :role, Ecto.Enum, values: [:user, :operator, :assistant, :tool]
    field :sender_id, :string
    # The speaking lane for agent transcripts (an agent role, or a system kind
    # such as "halted" / "failed"). nil for human (user/operator) messages.
    field :agent_role, :string
    # Calls this assistant turn made. nil on every other kind of turn.
    field :tool_calls, {:array, :map}
    # The call a :tool turn is answering.
    field :tool_call_id, :string
    # Whether that call came back an error (the provider's `is_error`).
    # Defaults false here rather than in the migration.
    field :tool_failed, :boolean, default: false
    # Where the widget that sent this was running, as its host app reported at
    # connect time. Provisioning's widget step gates on it: a message proves the
    # widget works only if it arrived from the deployed site.
    field :origin, :string
    # Whether the agent this was sent at has it. nil for everything that is not
    # an operator message at an agent.
    field :delivery, Ecto.Enum, values: [:delivered, :pending, :withdrawn, :failed]
    # The sender's handle on it while it can still be taken back, minted before
    # it leaves, so a withdrawal names the message rather than its text.
    field :delivery_ref, :string
    field :mailbox_state, :string, virtual: true
    field :delivery_diagnostic, :string, virtual: true

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Text of every text part, joined. The preview the inbox and search want.

  Derived on read rather than stored, so it cannot drift.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: parts}) do
    parts
    |> Enum.filter(&(part_type(&1) == "text"))
    |> Enum.map_join("\n", &(get(&1, "text") || ""))
  end

  @doc "The file parts, in order."
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

  `agent_id` lives on `conversations`, so this joins back through it and
  returns each row's `agent_id`. Callers that already hold the conversations
  use `by_conversations/2`.
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
  conversations. The content is not selected (it is the bulk of a transcript);
  `content_of/1` reads it back for the few rows whose text is reported.
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
  # of a transcript and nothing reads it.
  @intervention_senders ["operator", "system:restart"]

  @doc """
  The interventions among `conversation_ids`: the `:operator` messages whose
  sender says a person acted or a restart was performed, with their text.

  Narrow on both axes a transcript is large in, the sender and the content.

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

  # Who wrote a message with nothing in it: a warning with the stack, on a path
  # that should no longer happen. Not a validation — refusing would lose what
  # else the row carries; the point is to find the writer.
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

  # A human message must say or carry something.
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
