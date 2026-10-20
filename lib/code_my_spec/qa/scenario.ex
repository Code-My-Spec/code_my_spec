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
    field :blocker_issue_id, :binary_id
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

  @doc "Validate an attempt's verdict and its declared scenario blockers."
  @spec validate_attempt(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_attempt(changeset) do
    scenarios = get_field(changeset, :scenarios) || []
    issue_ids = get_field(changeset, :issue_ids) || []

    changeset =
      if get_field(changeset, :status) == :pass and
           Enum.any?(scenarios, &(&1.status in [:fail, :blocked])) do
        add_error(changeset, :status, "cannot be pass with failed or blocked scenarios")
      else
        changeset
      end

    missing_blocker? =
      Enum.any?(scenarios, fn scenario ->
        scenario.status == :blocked and not is_nil(scenario.blocker_issue_id) and
          scenario.blocker_issue_id not in issue_ids
      end)

    if missing_blocker?,
      do:
        add_error(changeset, :issue_ids, "must include every blocked scenario's blocker issue id"),
      else: changeset
  end
end
