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
  def change do
    alter table(:files) do
      add :story_id, references(:stories, on_delete: :nilify_all)
    end

    create index(:files, [:story_id])
  end
end
