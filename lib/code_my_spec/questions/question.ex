defmodule CodeMySpec.Questions.Question do
  @moduledoc """
  Ecto schema for a Question (red card) raised during a Three Amigos
  session.

  Questions are the parking lot for things neither the agent nor the PM
  can answer in the moment. They belong to a Story and are status-tracked
  through `:open → :resolved | :deferred`. Open questions count against
  the readiness gate (`scenarios > questions`); resolved/deferred are
  historical.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @statuses [:open, :resolved, :deferred]

  @type status :: :open | :resolved | :deferred

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          text: String.t() | nil,
          status: status() | nil,
          resolution: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "questions" do
    field :text, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :resolution, :string

    belongs_to :account, Account, type: :binary_id
    belongs_to :project, Project, type: :binary_id
    belongs_to :story, Story

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid question statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc false
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:account_id, :project_id, :story_id, :text, :status, :resolution])
    |> validate_required([:account_id, :project_id, :story_id, :text])
    |> validate_length(:text, min: 1, max: 2000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:project)
    |> assoc_constraint(:story)
  end
end
