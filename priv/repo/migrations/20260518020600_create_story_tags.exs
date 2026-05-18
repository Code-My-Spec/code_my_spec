defmodule CodeMySpec.Repo.Migrations.CreateStoryTags do
  use Ecto.Migration

  # The `Tags.StoryTag` schema declares `schema "story_tags"` but the
  # table was never created on the Postgres side (Postgres has `tags`,
  # `content_tags`, `component_tags` but no `story_tags`). The
  # `show_story_requirements` MCP tool crashed with `undefined_table`.
  # The CLI SQLite has this table but with a wrong FK (references
  # `component_tags(id)` instead of `tags(id)`) — Postgres gets the
  # correct one here.
  def change do
    create table(:story_tags) do
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
      add :story_id, references(:stories, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:story_tags, [:tag_id, :story_id])
    create index(:story_tags, [:story_id])
  end
end
