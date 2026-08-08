defmodule CodeMySpec.Repo.Migrations.AddMigratedFromIdToStories do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_migrated_from_id_to_stories`.

  Mirrored even though the harness is the *source* of a migration rather than
  its destination, and so has nothing to record here. The two deployments share
  one Ecto schema: a field the schema selects and SQLite lacks is how
  `SocketSupervisor` crashes on boot and takes MCP down with it.

  It also stops being hypothetical the moment anything migrates *into* a
  harness — a sprite seeded from the server, say — and a column that exists on
  both sides costs nothing now and a migration under a running CLI later.

  `add` rather than `modify`, deliberately: `modify` compiles to ALTER COLUMN,
  which SQLite does not have, and because the migrator is a supervised child
  that is not a failed migration but a CLI that will not start. Two migrations
  in this set did exactly that today.
  """

  def change do
    alter table(:stories) do
      add :migrated_from_id, :integer
    end

    create unique_index(:stories, [:project_id, :migrated_from_id],
             where: "migrated_from_id IS NOT NULL",
             name: :stories_project_id_migrated_from_id_index
           )
  end
end
