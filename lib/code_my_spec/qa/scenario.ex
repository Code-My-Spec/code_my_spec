defmodule CodeMySpec.Qa.Scenario do
  @moduledoc """
  Embedded schema for a single QA scenario within a QA attempt.

  Blocked scenarios were not run and must identify their blocker issue.
  Observations describe the finding, confirmation, or reason for the block.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pass, :partial, :fail, :blocked]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          status: :pass | :partial | :fail | :blocked | nil,
          observation: String.t() | nil,
          blocker_issue_id: Ecto.UUID.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :name, :string
    field :status, Ecto.Enum, values: @statuses
    field :observation, :string
    field :blocker_issue_id, Ecto.UUID
  end

  @doc "Changeset for a Scenario."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scenario \\ %__MODULE__{}, attrs) do
    scenario
    |> cast(attrs, [:name, :status, :observation, :blocker_issue_id])
    |> validate_required([:name, :status, :observation])
    |> require_blocker()
  end

  defp require_blocker(changeset) do
    if get_field(changeset, :status) == :blocked,
      do: validate_required(changeset, [:blocker_issue_id]),
      else: changeset
  end
end
