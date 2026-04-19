defmodule CodeMySpec.Configurations.ProjectConfiguration do
  @moduledoc """
  Local quality gate configuration for a project.

  One record per project. Controls:

  - Requirement toggles (what's required for a component to be "done")
  - Analyzer modes (what runs at stop time and whether it blocks)

  Lives only in the local DB — never synced to the server. The engineer
  is the only persona who touches this.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @analyzer_modes [:off, :block_all, :block_changed, :dont_block]
  @compile_modes [:block, :dont_block]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type analyzer_mode :: :off | :block_all | :block_changed | :dont_block
  @type compile_mode :: :block | :dont_block

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          require_specs: boolean(),
          require_reviews: boolean(),
          require_unit_tests: boolean(),
          compile_warnings: compile_mode(),
          credo: analyzer_mode(),
          exunit: analyzer_mode(),
          spex: analyzer_mode(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_configurations" do
    field :project_id, :binary_id

    # Requirement toggles
    field :require_specs, :boolean, default: true
    field :require_reviews, :boolean, default: true
    field :require_unit_tests, :boolean, default: true

    # Analyzer modes
    field :compile_warnings, Ecto.Enum, values: @compile_modes, default: :block
    field :credo, Ecto.Enum, values: @analyzer_modes, default: :block_changed
    field :exunit, Ecto.Enum, values: @analyzer_modes, default: :block_all
    field :spex, Ecto.Enum, values: @analyzer_modes, default: :off

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :project_id,
      :require_specs,
      :require_reviews,
      :require_unit_tests,
      :compile_warnings,
      :credo,
      :exunit,
      :spex
    ])
    |> validate_required([:project_id])
    |> unique_constraint(:project_id)
  end
end
