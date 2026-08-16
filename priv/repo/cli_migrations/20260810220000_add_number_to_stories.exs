defmodule CodeMySpec.Repo.Migrations.AddNumberToStories do
  @moduledoc """
  The CLI's mirror of the story number column — the column and its index, and
  deliberately not the server's backfill.

  The server migration seeds numbers out of spex directory names, because the
  server is where those names and the drift between them and the primary key
  came from. This database is a mirror: stories arrive here by sync, carrying
  whatever number the server settled on. Backfilling locally would compute a
  second answer to a question already answered upstream, and then have to be
  overwritten by the next sync.

  It also could not run. The backfill was mirrored verbatim, so it reached
  SQLite as `split_part(...)` and a `::integer` cast, and SQLite has neither:

      ** (Exqlite.Error) unrecognized token: ":"

  `CodeMySpecLocalWeb.Migrator` is a child of the application supervisor, so
  that did not skip a migration — it stopped the app from starting at all.
  Neither `cli_dev.db` nor the published binary's `cli.db` had ever got past
  it, so the next release carrying it would have failed to boot for every
  existing user, not only for a fresh install, with no way in through the
  product to repair the database.

  Nullable, like the server's, and for the same reason recorded there: a column
  existing rows satisfy and new rows cannot is the worst ordering. Multiple
  NULLs coexist under the unique index in SQLite, so unsynced rows sit quietly
  until sync fills them in.
  """
  use Ecto.Migration

  def up do
    alter table(:stories) do
      add :number, :integer
    end

    # Per project, not global: two projects each numbering from their own
    # filenames must not collide.
    create unique_index(:stories, [:project_id, :number])
  end

  def down do
    drop index(:stories, [:project_id, :number])

    alter table(:stories) do
      remove :number
    end
  end
end
