defmodule CodeMySpec.Qa.IssueQaAttempt do
  @moduledoc """
  Schema for a QA attempt on an issue (story 1091).

  The issue counterpart to `QaAttempt`, kept separate rather than widening
  that schema: a story attempt satisfies `qa_complete` through the
  requirement graph, an issue's passing attempt — with its fix landed —
  resolves it and frees its team (`CodeMySpec.Qa.IssueQaAttempts`) — different
  enough machinery downstream that sharing the table would mean every
  story-side query guarding against a nil `story_id` it used to be able to
  assume.

  Immutable once inserted, same as `QaAttempt`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.Scenario

  @statuses [:pass, :partial, :fail]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          issue_id: Ecto.UUID.t() | nil,
          status: :pass | :partial | :fail | nil,
          scenarios: [Scenario.t()],
          issue_ids: [Ecto.UUID.t()],
          agent_id: String.t() | nil,
          task_id: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "issue_qa_attempts" do
    field :status, Ecto.Enum, values: @statuses
    field :issue_ids, {:array, :binary_id}, default: []
    field :agent_id, :string
    field :task_id, :string
    field :submitted_at, :utc_datetime_usec

    embeds_many :scenarios, Scenario, on_replace: :delete

    belongs_to :issue, Issue, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating an IssueQaAttempt."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attempt \\ %__MODULE__{}, attrs) do
    attempt
    |> cast(attrs, [:issue_id, :status, :issue_ids, :agent_id, :task_id, :submitted_at])
    |> cast_embed(:scenarios, required: true)
    |> validate_required([:issue_id, :status, :submitted_at])
    |> validate_scenarios_non_empty()
    |> Scenario.validate_attempt()
  end

  defp validate_scenarios_non_empty(changeset) do
    case get_field(changeset, :scenarios) do
      [] -> add_error(changeset, :scenarios, "must have at least one scenario")
      nil -> add_error(changeset, :scenarios, "must have at least one scenario")
      _ -> changeset
    end
  end
end
