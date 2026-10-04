defmodule CodeMySpec.Stories.AcceptanceCriteria.Criterion do
  @moduledoc """
  Ecto schema representing a single acceptance criterion.

  Acceptance criteria belong to stories and represent testable conditions
  that define when a story is complete. Each criterion has a description,
  verification status, and timestamp tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @kinds [:happy_path, :failure_path]

  @type kind :: :happy_path | :failure_path

  @type t :: %__MODULE__{
          id: integer() | nil,
          number: integer() | nil,
          retired_at: DateTime.t() | nil,
          latched_at: DateTime.t() | nil,
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

    # The criterion's name for life: per project, minted on insert, never
    # reused. `id` is a per-deployment sequence and changes on migration.
    field :number, :integer

    # Criteria are retired, never deleted, so a number is never freed.
    field :retired_at, :utc_datetime_usec

    # This criterion's own counterpart to `stories.specs_ready_at`: when a
    # certifying run last found it green. Set directly here; what sets it
    # and what reads it back belongs to the callers that do so.
    field :latched_at, :utc_datetime_usec

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
      :spec_path,
      :number,
      :retired_at,
      :latched_at
    ])
    |> validate_required([
      :description,
      :story_id,
      :project_id
    ])
    |> foreign_key_constraint(:story_id, message: "story does not exist")
    |> foreign_key_constraint(:rule_id, message: "rule does not exist")
    |> mint_number()
  end

  @doc "Retire a criterion. It keeps its row and its number."
  def retire_changeset(criterion),
    do: change(criterion, retired_at: DateTime.utc_now())

  @doc "Bring a retired criterion back under its number."
  def restore_changeset(criterion), do: change(criterion, retired_at: nil)

  @doc "Latch a criterion directly, as a certifying run would."
  def latch_changeset(criterion), do: change(criterion, latched_at: DateTime.utc_now())

  # One above the highest in the project, retired included, so a number is
  # never handed out twice. Taken inside the insert's transaction; the unique
  # index on `(project_id, number)` catches a concurrent collision. An
  # explicitly supplied number wins, which is how migration keeps it.
  defp mint_number(changeset) do
    prepare_changes(changeset, fn changeset ->
      if changeset.action == :insert and is_nil(get_field(changeset, :number)) do
        project_id = get_field(changeset, :project_id)

        highest =
          changeset.repo.one(
            from(c in __MODULE__, where: c.project_id == ^project_id, select: max(c.number))
          )

        put_change(changeset, :number, (highest || 0) + 1)
      else
        changeset
      end
    end)
    |> unique_constraint([:project_id, :number])
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
    |> mint_number()
  end
end
