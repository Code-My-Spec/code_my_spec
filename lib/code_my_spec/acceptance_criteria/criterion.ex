defmodule CodeMySpec.AcceptanceCriteria.Criterion do
  @moduledoc """
  Ecto schema representing a single acceptance criterion.

  Acceptance criteria belong to stories and represent testable conditions
  that define when a story is complete. Each criterion has a description,
  verification status, and timestamp tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:happy_path, :failure_path]

  @type kind :: :happy_path | :failure_path

  @type t :: %__MODULE__{
          id: integer() | nil,
          description: String.t(),
          body: String.t() | nil,
          kind: kind() | nil,
          verified: boolean(),
          verified_at: DateTime.t() | nil,
          story_id: integer() | nil,
          project_id: Ecto.UUID.t() | nil,
          rule_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "criteria" do
    field :description, :string
    field :body, :string
    field :kind, Ecto.Enum, values: @kinds
    field :verified, :boolean, default: false
    field :verified_at, :utc_datetime
    field :project_id, :binary_id
    field :rule_id, :binary_id

    # Where this criterion's spex file is, recorded rather than derived. The
    # derived path was pinned to the id and a slug of the description, and both
    # move — the id on migration, the slug whenever somebody edits the words.
    field :spec_path, :string

    belongs_to :story, CodeMySpec.Stories.Story

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid scenario kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc false
  def changeset(criterion, attrs) do
    criterion
    |> cast(attrs, [
      :description,
      :body,
      :kind,
      :verified,
      :verified_at,
      :story_id,
      :project_id,
      :rule_id,
      :spec_path
    ])
    |> validate_required([
      :description,
      :story_id,
      :project_id
    ])
    |> foreign_key_constraint(:story_id, message: "story does not exist")
    |> foreign_key_constraint(:rule_id, message: "rule does not exist")
  end

  @doc """
  Changeset for nested forms via cast_assoc.
  story_id is set automatically via the association.
  project_id is injected by the story's repository.
  """
  def nested_changeset(criterion, attrs) do
    criterion
    |> cast(attrs, [
      :description,
      :body,
      :kind,
      :verified,
      :verified_at,
      :project_id,
      :rule_id
    ])
    |> validate_required([:description])
  end
end
