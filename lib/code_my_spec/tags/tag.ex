defmodule CodeMySpec.Tags.Tag do
  @moduledoc """
  Ecto schema for tags.

  Tags are simple string identifiers used to organize stories.
  Unique by name within a project.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Tags.StoryTag

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          story_tags: [StoryTag.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Uses component_tags table to avoid conflict with content tags
  schema "component_tags" do
    field :name, :string

    belongs_to :project, Project, type: :binary_id
    has_many :story_tags, StoryTag

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :project_id])
    |> validate_required([:name, :project_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:name, ~r/^[a-zA-Z0-9_\-:\.]+$/,
      message: "must contain only letters, numbers, underscores, hyphens, colons, and dots"
    )
    |> unique_constraint([:name, :project_id])
  end
end
