defmodule CodeMySpec.Repo.Migrations.AddStoryIdToFiles do
  use Ecto.Migration

  # The `Files` schema declares `belongs_to :story` but the column was
  # never created on the Postgres side. `20260328193741_create_files`
  # was edited after it was applied (the file has the column today but
  # production was migrated against an older version). MCP tools that
  # join through `files.story_id` (`show_requirement`,
  # `show_component_requirements`, `show_story_requirements`) crashed
  # with `undefined_column`. The CLI SQLite migration already had this
  # — bringing Postgres in line.
  #
  # Uses raw SQL with conditional DDL so the migration is idempotent for
  # test databases that were seeded from the edited `create_files`
  # migration which already included the column and FK constraint.
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
