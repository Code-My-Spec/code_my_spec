defmodule CodeMySpec.Dependencies.Dependency do
  @moduledoc """
  One package a project depends on, as recorded from its `mix.lock`.

  `projected_version` is unused: it tracked the retired working-tree hex doc
  projector. The column stays until a migration drops it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "project_dependencies" do
    field :name, :string
    field :version, :string
    field :source, :string
    field :checksum, :string
    field :projected_version, :string

    belongs_to :project, CodeMySpec.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:name, :version, :source, :checksum, :projected_version, :project_id])
    |> validate_required([:name, :project_id])
    |> unique_constraint([:project_id, :name])
  end
end
