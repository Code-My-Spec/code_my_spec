defmodule CodeMySpec.Stories.Story do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.AcceptanceCriteria.Criterion

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t(),
          description: String.t(),
          acceptance_criteria: [String.t()],
          criteria: [CodeMySpec.AcceptanceCriteria.Criterion.t()],
          tags: [CodeMySpec.Tags.Tag.t()] | Ecto.Association.NotLoaded.t(),
          status: :active | :in_progress | :completed | :dirty,
          priority: integer() | nil,
          locked_at: DateTime.t() | nil,
          lock_expires_at: DateTime.t() | nil,
          locked_by: integer() | nil,
          project_id: Ecto.UUID.t() | nil,
          component_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          first_version: PaperTrail.Version.t() | nil,
          current_version: PaperTrail.Version.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Field descriptions for API documentation."
  def field_docs do
    %{
      title: "Story title, e.g. 'User Login Feature'",
      description: "User story in 'As a [role], I want [goal] so that [value]' format",
      acceptance_criteria: "List of acceptance criteria strings",
      priority: "Priority order (1 = highest). Lower numbers are higher priority",
      status: "Story status: in_progress, completed, or dirty",
      component_id: "Linked component ID"
    }
  end

  schema "stories" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, {:array, :string}
    # `:active` is a legacy status that predates the narrowed enum
    # (`:in_progress | :completed | :dirty`). Accepted on read to
    # tolerate stale rows on remote servers; new writes use the
    # narrowed values.
    field :status, Ecto.Enum, values: [:active, :in_progress, :completed, :dirty]
    field :priority, :integer
    field :locked_at, :utc_datetime
    field :lock_expires_at, :utc_datetime
    field :locked_by, :id
    field :project_id, :binary_id
    field :account_id, :binary_id

    has_many :criteria, CodeMySpec.AcceptanceCriteria.Criterion, on_replace: :delete

    many_to_many :tags, CodeMySpec.Tags.Tag,
      join_through: CodeMySpec.Tags.StoryTag,
      on_replace: :delete

    belongs_to :first_version, PaperTrail.Version
    belongs_to :current_version, PaperTrail.Version, on_replace: :update
    belongs_to :component, CodeMySpec.Components.Component, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(story, attrs) do
    story
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :priority,
      :locked_at,
      :lock_expires_at,
      :locked_by,
      :project_id,
      :component_id
    ])
    |> validate_required([
      :title,
      :description
    ])
    |> cast_assoc(:criteria,
      with: &Criterion.nested_changeset/2,
      sort_param: :criteria_sort,
      drop_param: :criteria_drop
    )
    |> unique_constraint([:title, :project_id])
  end

  @doc false
  def lock_changeset(story, attrs) do
    story
    |> cast(attrs, [
      :locked_at,
      :lock_expires_at,
      :locked_by
    ])
  end
end
