defmodule CodeMySpec.Files.File do
  @moduledoc """
  Represents a tracked file in the project filesystem.

  Files are the connective tissue between the filesystem and the domain model.
  Each file has a role (spec, implementation, test, etc.) and belongs to an owner
  (component, story, or project). The path is the natural join key — when an
  analyzer reports a problem at a path, the File record links it to the owner.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @roles [
    :spec,
    :implementation,
    :test,
    :rule,
    :json,
    :review,
    :bdd_spec,
    :qa_brief,
    :qa_result,
    :config,
    :architecture,
    :integration
  ]

  @type role ::
          :spec
          | :implementation
          | :test
          | :rule
          | :json
          | :review
          | :bdd_spec
          | :qa_brief
          | :qa_result
          | :config
          | :architecture
          | :integration

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          path: String.t(),
          role: role(),
          mtime: DateTime.t() | nil,
          size: integer() | nil,
          valid: boolean() | nil,
          validation_errors: map() | nil,
          component_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          project_id: Ecto.UUID.t(),
          component: Component.t() | Ecto.Association.NotLoaded.t(),
          story: Story.t() | Ecto.Association.NotLoaded.t(),
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "files" do
    field :path, :string
    field :role, Ecto.Enum, values: @roles
    field :mtime, :utc_datetime
    field :size, :integer
    field :valid, :boolean
    field :validation_errors, :map

    belongs_to :component, Component, type: :binary_id
    belongs_to :story, Story
    belongs_to :project, Project, type: :binary_id

    timestamps()
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:path, :role, :mtime, :size, :valid, :validation_errors, :component_id, :story_id, :project_id])
    |> validate_required([:path, :role, :project_id])
    |> unique_constraint([:project_id, :path])
  end

  @doc "All valid file roles."
  def roles, do: @roles
end
