defmodule CodeMySpec.Repo.Migrations.CreateStoryDependencies do
  use Ecto.Migration

  def up do
    # SQLite requires CHECK constraints in the original CREATE TABLE.
    execute """
    CREATE TABLE story_dependencies (
      story_id INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
      builds_on_id INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
      CONSTRAINT story_dependencies_no_self_link CHECK (story_id <> builds_on_id)
    )
    """

    create unique_index(:story_dependencies, [:story_id, :builds_on_id])
    create index(:story_dependencies, [:builds_on_id])
  end

  def down do
    drop table(:story_dependencies)
  end
end
