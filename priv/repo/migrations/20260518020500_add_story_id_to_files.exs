defmodule CodeMySpec.Repo.Migrations.AddStoryIdToFiles do
  use Ecto.Migration

  # Adds `files.story_id` to support `belongs_to :story` on the Files
  # schema. Prod was migrated against an early working copy of
  # `20260328193741_create_files` that did not include the column, so
  # MCP tools joining through `files.story_id` (`show_requirement`,
  # `show_component_requirements`, `show_story_requirements`) crashed
  # with `undefined_column` until this migration ran. The CLI SQLite
  # migration had the column from the start — this brings Postgres in
  # line.
  #
  # Uses raw SQL with `DO $$ ... IF NOT EXISTS` blocks so the migration
  # is idempotent for dev/CI environments whose `create_files` migration
  # already added the column from a since-reverted version of that file.
  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'files' AND column_name = 'story_id'
      ) THEN
        ALTER TABLE files ADD COLUMN story_id bigint REFERENCES stories(id) ON DELETE SET NULL;
      END IF;
    END
    $$;
    """

    execute """
    CREATE INDEX IF NOT EXISTS files_story_id_index ON files (story_id);
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS files_story_id_index;"

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'files' AND column_name = 'story_id'
      ) THEN
        ALTER TABLE files DROP COLUMN story_id;
      END IF;
    END
    $$;
    """
  end
end
