defmodule CodeMySpec.Repo.Migrations.SimplifyTagsSchema do
  use Ecto.Migration

  def up do
    # Drop the overengineered polymorphic tagging system
    drop_if_exists table(:component_taggings)

    # Drop the taggable_type enum
    execute("DROP TYPE IF EXISTS taggable_type")

    # Create simple story_tags join table
    create table(:story_tags) do
      add :tag_id, references(:component_tags, on_delete: :delete_all), null: false
      add :story_id, references(:stories, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:story_tags, [:tag_id, :story_id])
    create index(:story_tags, [:tag_id])
    create index(:story_tags, [:story_id])
  end

  def down do
    # Drop simple story_tags
    drop_if_exists table(:story_tags)

    # Recreate taggable_type enum
    execute(
      "CREATE TYPE taggable_type AS ENUM ('story', 'component')",
      "DROP TYPE taggable_type"
    )

    # Recreate component_taggings table
    create table(:component_taggings) do
      add :tag_id, references(:component_tags, on_delete: :delete_all), null: false
      add :taggable_type, :taggable_type, null: false
      add :taggable_id, :binary, null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:component_taggings, [:tag_id, :taggable_type, :taggable_id])
    create index(:component_taggings, [:taggable_type, :taggable_id])
    create index(:component_taggings, [:project_id])
    create index(:component_taggings, [:tag_id])
  end
end
