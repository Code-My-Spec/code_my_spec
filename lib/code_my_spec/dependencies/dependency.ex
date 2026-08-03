defmodule CodeMySpec.Dependencies.Dependency do
  @moduledoc """
  One package a project depends on, as recorded from its `mix.lock`.

  `projected_version` is what makes this more than a list: a package needs its
  documentation projected exactly when `projected_version != version`. NULL
  means never projected. That single comparison is what replaced a ten-second
  settle timer, and unlike the timer it has an end state something can wait for.
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
    field :projected_version, :string

    belongs_to :project, CodeMySpec.Projects.Project

    timestamps(type: :utc_datetime)
  end

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:name, :version, :source, :projected_version, :project_id])
    |> validate_required([:name, :project_id])
    |> unique_constraint([:project_id, :name])
  end
end
