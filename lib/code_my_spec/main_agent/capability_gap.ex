defmodule CodeMySpec.MainAgent.CapabilityGap do
  @moduledoc """
  Something a role should have been able to do, and how often the main agent
  covered for its absence.

  One row per `{project, role, capability}`, which is the whole point: a gap is
  one thing however many times it bites. Forty copies of one missing tool in a
  backlog is not merely untidy — triage that opens on forty copies of the same
  thing learns to skim, and the next real issue is skimmed with them.

  `occurrences` is the half that would be lost to plain deduplication. Not
  filing again throws away the evidence that decides whether this gap is worth
  closing before the next thing, and leaves triage with one data point and no
  idea it is the tip of anything.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          role: String.t() | nil,
          capability: String.t() | nil,
          occurrences: integer() | nil,
          issue_id: Ecto.UUID.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "capability_gaps" do
    field :project_id, Ecto.UUID
    field :role, :string
    field :capability, :string
    field :occurrences, :integer, default: 1
    field :issue_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(gap, attrs) do
    gap
    |> cast(attrs, [:project_id, :role, :capability, :occurrences, :issue_id])
    |> validate_required([:project_id, :role, :capability, :occurrences])
    |> unique_constraint([:project_id, :role, :capability])
  end
end
