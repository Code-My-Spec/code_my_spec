defmodule CodeMySpec.Personas.Persona do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @type persona_type :: :proto | :qualitative | :statistical

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          headline: String.t() | nil,
          persona_type: persona_type() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          stories: [Story.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @persona_types [:proto, :qualitative, :statistical]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "personas" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :persona_type, Ecto.Enum, values: @persona_types, default: :proto

    belongs_to :project, Project, type: :binary_id
    many_to_many :stories, Story, join_through: PersonaStory

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the list of valid persona types."
  @spec persona_types() :: [persona_type()]
  def persona_types, do: @persona_types

  @doc false
  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [:project_id, :slug, :name, :headline, :persona_type])
    |> validate_required([:project_id, :slug, :name])
    |> validate_length(:slug, min: 1, max: 64)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:headline, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase alphanumeric with underscores or hyphens"
    )
    |> unique_constraint([:project_id, :slug])
    |> assoc_constraint(:project)
  end
end
