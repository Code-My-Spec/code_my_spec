defmodule CodeMySpec.Repo.Migrations.AddStoryAndProjectToRequirements do
  use Ecto.Migration

  @doc """
  Adds story_id and project_id to requirements, makes component_id nullable.

  SQLite does not support ALTER COLUMN, so we drop and recreate the table.
  Existing requirement records are recalculated on every sync, so no data migration needed.
  """

  def up do
    execute "DROP INDEX IF EXISTS requirements_component_id_name_index"
    execute "DROP INDEX IF EXISTS requirements_component_id_index"
    execute "DROP INDEX IF EXISTS requirements_artifact_type_index"
    execute "DROP TABLE IF EXISTS requirements"

    create table(:requirements) do
      add :name, :string, null: false
      add :artifact_type, :string, null: false, default: "specification"
      add :description, :string, null: false
      add :checker_module, :string, null: false
      add :satisfied_by, :string
      add :satisfied, :boolean, default: false, null: false
      add :score, :float
      add :checked_at, :utc_datetime
      add :details, :map, default: %{}
      add :component_id, :binary_id, null: true
      add :story_id, :bigint, null: true
      add :project_id, :binary_id, null: true

      timestamps(type: :utc_datetime)
    end

    create index(:requirements, [:component_id])
    create index(:requirements, [:artifact_type])
    create index(:requirements, [:story_id])
    create index(:requirements, [:project_id])

    create unique_index(:requirements, [:component_id, :name],
      where: "component_id IS NOT NULL",
      name: :requirements_component_id_name_index
    )

    create unique_index(:requirements, [:story_id, :name],
      where: "story_id IS NOT NULL",
      name: :requirements_story_id_name_index
    )

    create unique_index(:requirements, [:project_id, :name],
      where: "project_id IS NOT NULL",
      name: :requirements_project_id_name_index
    )
  end

  def down do
    execute "DROP INDEX IF EXISTS requirements_component_id_name_index"
    execute "DROP INDEX IF EXISTS requirements_story_id_name_index"
    execute "DROP INDEX IF EXISTS requirements_project_id_name_index"
    execute "DROP INDEX IF EXISTS requirements_component_id_index"
    execute "DROP INDEX IF EXISTS requirements_artifact_type_index"
    execute "DROP INDEX IF EXISTS requirements_story_id_index"
    execute "DROP INDEX IF EXISTS requirements_project_id_index"
    execute "DROP TABLE IF EXISTS requirements"

    create table(:requirements) do
      add :name, :string, null: false
      add :artifact_type, :string, null: false, default: "specification"
      add :description, :string, null: false
      add :checker_module, :string, null: false
      add :satisfied_by, :string
      add :satisfied, :boolean, default: false, null: false
      add :score, :float
      add :checked_at, :utc_datetime
      add :details, :map, default: %{}

      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:requirements, [:component_id])
    create index(:requirements, [:artifact_type])
    create unique_index(:requirements, [:component_id, :name])
  end
end
