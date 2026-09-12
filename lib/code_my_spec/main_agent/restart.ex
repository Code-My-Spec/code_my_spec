defmodule CodeMySpec.MainAgent.Restart do
  @moduledoc """
  One restart the main agent performed, and what it was for.

  The record a person supplied by remembering. A main agent restarts on its own
  judgement and far more often than anybody would by hand, so "have I tried this
  already, and did it work" has to be answerable from rows rather than from
  whatever is still in context.

  `resolved_at` is set when the agent is seen working after the restart. It is
  the difference between a count of attempts and a count of *failed* attempts,
  and story 1056's 3292 and 3302 pull in opposite directions across exactly that
  line: refuse a remedy that has not worked, and do not hold a remedy that did
  against the next recurrence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          agent_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          reason: String.t() | nil,
          resolved_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_restarts" do
    field :agent_id, Ecto.UUID
    field :project_id, Ecto.UUID
    field :reason, :string
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(restart, attrs) do
    restart
    |> cast(attrs, [:agent_id, :project_id, :reason, :resolved_at])
    |> validate_required([:agent_id, :project_id, :reason])
  end
end
