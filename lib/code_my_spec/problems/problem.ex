defmodule CodeMySpec.Problems.Problem do
  @moduledoc """
  Schema representing a normalized problem from any analysis or testing tool.
  Supports both ephemeral (in-memory) usage during sessions and persistent storage
  for project-level fitness tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Harnesses.Harness
  alias CodeMySpec.Projects.Project

  @type t :: %__MODULE__{
          id: integer() | nil,
          severity: :error | :warning | :info,
          source_type: :static_analysis | :test | :runtime,
          source: String.t(),
          file_path: String.t(),
          line: integer() | nil,
          message: String.t(),
          category: String.t(),
          rule: String.t() | nil,
          metadata: map() | nil,
          component_id: Ecto.UUID.t() | nil,
          component: Component.t() | Ecto.Association.NotLoaded.t(),
          project_id: Ecto.UUID.t(),
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "problems" do
    field :severity, Ecto.Enum, values: [:error, :warning, :info]
    field :source_type, Ecto.Enum, values: [:static_analysis, :test, :runtime]
    field :source, :string
    field :file_path, :string
    field :line, :integer
    field :message, :string
    field :category, :string
    field :rule, :string
    field :metadata, :map

    belongs_to :component, Component, type: :binary_id
    belongs_to :project, Project, type: :binary_id

    # The working copy these were observed from. `nil` means "recorded before
    # harnesses existed"; the first harness to join adopts them.
    belongs_to :harness, Harness, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating a Problem with validation.
  """
  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(problem, attrs) do
    problem
    |> cast(attrs, [
      :severity,
      :source_type,
      :source,
      :file_path,
      :line,
      :message,
      :category,
      :rule,
      :metadata,
      :component_id,
      :project_id,
      :harness_id
    ])
    |> put_default_source_type()
    |> validate_required([
      :severity,
      :source_type,
      :source,
      :file_path,
      :message,
      :category,
      :project_id
    ])
    |> validate_length(:source, min: 1, max: 255)
    |> validate_length(:file_path, min: 1)
    |> validate_length(:category, min: 1, max: 255)
    |> validate_number(:line, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:component_id)
  end

  defp put_default_source_type(changeset) do
    case get_field(changeset, :source_type) do
      nil -> put_change(changeset, :source_type, :static_analysis)
      _value -> changeset
    end
  end
end
