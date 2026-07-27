defmodule CodeMySpec.Epics.Epic do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          stories: [Story.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "epics" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :account_id, Ecto.UUID

    belongs_to :project, Project, type: :binary_id
    has_many :stories, Story

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(epic, attrs) do
    epic
    |> cast(attrs, [:project_id, :account_id, :name, :description])
    |> put_slug()
    |> validate_required([:project_id, :name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:project_id, :name])
    |> assoc_constraint(:project)
  end

  # The slug is derived from the name rather than supplied — an epic is a
  # user-facing label, and two epics with the same name in one project are
  # already rejected by the unique constraint.
  defp put_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  @doc "Converts an epic name into its URL slug."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
