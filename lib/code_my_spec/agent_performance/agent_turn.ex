defmodule CodeMySpec.AgentPerformance.AgentTurn do
  @moduledoc """
  One agent turn's token usage, as the provider reported it.

  A row always exists once a turn finishes, even when the provider reported
  no usage at all -- the row is what lets criterion 1978 tell "unknown" apart
  from "a turn that happened and cost nothing", which a missing row cannot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_turns" do
    field :account_id, :binary_id
    field :project_id, :binary_id
    field :agent_id, :binary_id
    field :story_id, :id
    field :provider, :string
    field :model, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_tokens, :integer
    field :cache_write_tokens, :integer

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @fields [
    :account_id,
    :project_id,
    :agent_id,
    :story_id,
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens
  ]

  @doc false
  def changeset(agent_turn, attrs) do
    agent_turn
    |> cast(attrs, @fields)
    |> validate_required([:account_id, :project_id, :agent_id])
  end
end
