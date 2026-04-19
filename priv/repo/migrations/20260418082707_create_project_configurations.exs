defmodule CodeMySpec.Repo.Migrations.CreateProjectConfigurations do
  use Ecto.Migration

  def change do
    create table(:project_configurations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Requirement toggles
      add :require_specs, :boolean
      add :require_reviews, :boolean
      add :require_unit_tests, :boolean

      # Analyzer modes
      add :compile_warnings, :string
      add :credo, :string
      add :exunit, :string
      add :spex, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_configurations, [:project_id])

    # Drop the old fields on projects — they move to project_configurations
    alter table(:projects) do
      remove :require_specs
      remove :require_unit_tests
    end
  end
end
