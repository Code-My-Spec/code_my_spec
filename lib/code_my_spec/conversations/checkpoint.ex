defmodule CodeMySpec.Conversations.Checkpoint do
  @moduledoc """
  Where an agent resumes a conversation from, once it is longer than a context.

  A conversation that runs for months cannot be handed back to a model whole,
  and truncating it loses the decisions that explain why the project looks the
  way it does. Alloy already solves that for a *running* agent: when the
  context fills it writes a handoff summary and keeps a recent window. This is
  that same decision, written down, so a *restarted* agent resumes from it
  rather than from the top.

  `messages` is what compaction kept — first message, summary, recent window —
  in the shape Alloy hands back. Stored as it came rather than re-derived: a
  second summary is a second reading of the same conversation, and the one the
  agent actually continued from is the one that matters.

  `through_message_id` is the last transcript row the summary covers. Resuming
  is `messages` plus every row after it, verbatim, which is what makes this a
  bound on history rather than a cut in it.

  Not a `role` on `conversation_messages`. A checkpoint is a fact about the
  conversation rather than a thing said in it, and putting it in the stream
  would mean every renderer, every preview and every `role` clause learning to
  skip a row that is not a message.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Conversations.{Conversation, Message}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "conversation_checkpoints" do
    # `[%{"role" => "user" | "assistant", "content" => …}]`, as Alloy holds
    # them. Maps rather than structs because this crosses a wire and a database
    # before it is anything again.
    field :messages, {:array, :map}, default: []
    field :turn, :integer

    belongs_to :conversation, Conversation
    belongs_to :through_message, Message

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:messages, :turn, :conversation_id, :through_message_id])
    |> validate_required([:conversation_id])
    |> validate_not_empty()
  end

  # Read with `get_field/2` rather than validated as a change.
  #
  # The field defaults to `[]`, so casting `[]` over it registers no change and
  # `validate_length/3` never runs; `validate_required/2` does not count an empty
  # list as blank either. Both passed, and an empty checkpoint would resume the
  # agent on an empty conversation — indistinguishable from a new one, and
  # written down as though the history had been kept.
  defp validate_not_empty(changeset) do
    case get_field(changeset, :messages) do
      [_ | _] ->
        changeset

      _ ->
        add_error(
          changeset,
          :messages,
          "a checkpoint with nothing in it is worse than none: resuming from it would " <>
            "silently start the agent on an empty conversation"
        )
    end
  end
end
