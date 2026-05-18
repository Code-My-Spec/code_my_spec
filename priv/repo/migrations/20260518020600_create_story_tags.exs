defmodule CodeMySpec.Repo.Migrations.CreateStoryTags do
  use Ecto.Migration

  # The `Tags.StoryTag` schema declares `schema "story_tags"` but the
  # table was never created on the Postgres side (Postgres has `tags`,
  # `content_tags`, `component_tags` but no `story_tags`). The
  # `show_story_requirements` MCP tool crashed with `undefined_table`.
  # The CLI SQLite has this table but with a wrong FK (references
  # `component_tags(id)` instead of `tags(id)`) — Postgres gets the
  # correct one here.
  #
  # Uses conditional DDL to be idempotent for test databases where the
  # table already exists.
  def up do
    execute """
    CREATE TABLE IF NOT EXISTS story_tags (
      id bigserial PRIMARY KEY,
      tag_id bigint NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
      story_id bigint NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    );
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS story_tags_tag_id_story_id_index ON story_tags (tag_id, story_id);"
    execute "CREATE INDEX IF NOT EXISTS story_tags_story_id_index ON story_tags (story_id);"
  end

  def down do
    execute "DROP TABLE IF EXISTS story_tags;"
  end
end
