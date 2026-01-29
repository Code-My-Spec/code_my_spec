defmodule CodeMySpec.Repo.Migrations.CreateComponentTags do
  use Ecto.Migration

  def change do
    # Create component_tags table for the Tags context
    # Named component_tags to distinguish from existing content tags table
    create table(:component_tags) do
      add :name, :string, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:component_tags, [:name, :project_id])
    create index(:component_tags, [:project_id])

    # Create taggable_type enum
    execute(
      "CREATE TYPE taggable_type AS ENUM ('story', 'component')",
      "DROP TYPE taggable_type"
    )

    # Create component_taggings join table
    # Uses binary taggable_id to handle both integer story IDs and UUID component IDs
    create table(:component_taggings) do
      add :tag_id, references(:component_tags, on_delete: :delete_all), null: false
      add :taggable_type, :taggable_type, null: false
      add :taggable_id, :binary, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:component_taggings, [:tag_id, :taggable_type, :taggable_id])
    create index(:component_taggings, [:taggable_type, :taggable_id])
    create index(:component_taggings, [:project_id])
    create index(:component_taggings, [:tag_id])
  end
end
