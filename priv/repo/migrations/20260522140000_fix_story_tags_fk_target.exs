defmodule CodeMySpec.Repo.Migrations.FixStoryTagsFkTarget do
  use Ecto.Migration

  # `20260518020600_create_story_tags.exs` accidentally pointed
  # `story_tags.tag_id` at `tags(id)` — a non-existent table on
  # Postgres. The `Tags.Tag` schema uses `component_tags` (per
  # `20260128213231_create_component_tags`); the Jan migration that
  # originally created `story_tags` (later replaced by the May one)
  # had the FK correct. Result: `TagStories.execute` silently
  # swallowed the FK violation as `{:error, _changeset}` and never
  # persisted any story → tag link.
  def up do
    execute "ALTER TABLE story_tags DROP CONSTRAINT IF EXISTS story_tags_tag_id_fkey;"

    execute """
    ALTER TABLE story_tags
      ADD CONSTRAINT story_tags_tag_id_fkey
      FOREIGN KEY (tag_id) REFERENCES component_tags(id) ON DELETE CASCADE;
    """
  end

  def down do
    execute "ALTER TABLE story_tags DROP CONSTRAINT IF EXISTS story_tags_tag_id_fkey;"

    execute """
    ALTER TABLE story_tags
      ADD CONSTRAINT story_tags_tag_id_fkey
      FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE;
    """
  end
end
