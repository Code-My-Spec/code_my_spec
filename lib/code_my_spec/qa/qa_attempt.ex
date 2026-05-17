defmodule CodeMySpec.Qa.QaAttempt do
  @moduledoc """
  Schema for a QA attempt on a story.

  Immutable once inserted. Each submission creates a new row. The latest
  attempt with `status: :pass` and no associated invalidation satisfies
  `qa_complete` for the story.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Qa.Invalidation
  alias CodeMySpec.Qa.Scenario
  alias CodeMySpec.Stories.Story

  @statuses [:pass, :partial, :fail]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          status: :pass | :partial | :fail | nil,
          scenarios: [Scenario.t()],
          issue_ids: [Ecto.UUID.t()],
          agent_id: String.t() | nil,
          task_id: String.t() | nil,
          parent_attempt_id: Ecto.UUID.t() | nil,
          submitted_at: DateTime.t() | nil,
          invalidations: [Invalidation.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "qa_attempts" do
    field :status, Ecto.Enum, values: @statuses
    field :issue_ids, {:array, :binary_id}, default: []
    field :agent_id, :string
    field :task_id, :string
    field :submitted_at, :utc_datetime_usec

    embeds_many :scenarios, Scenario, on_replace: :delete

    belongs_to :story, Story
    belongs_to :parent_attempt, __MODULE__, type: :binary_id
    has_many :invalidations, Invalidation

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a QaAttempt."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attempt \\ %__MODULE__{}, attrs) do
    attempt
    |> cast(attrs, [:story_id, :status, :issue_ids, :agent_id, :task_id, :parent_attempt_id,
                    :submitted_at])
    |> cast_embed(:scenarios, required: true)
    |> validate_required([:story_id, :status, :submitted_at])
    |> validate_scenarios_non_empty()
  end

  defp validate_scenarios_non_empty(changeset) do
    case get_field(changeset, :scenarios) do
      [] -> add_error(changeset, :scenarios, "must have at least one scenario")
      nil -> add_error(changeset, :scenarios, "must have at least one scenario")
      _ -> changeset
    end
  end
end
