defmodule CodeMySpec.CliRepo.Migrations.BackfillSyncedFromServer do
  use Ecto.Migration

  # Mirror of priv/repo/migrations/20260522160000 for the local CLI's
  # SQLite. `synced_from_server` was added in 20260518024054 (also
  # mirrored) without a backfill. Every existing row in the local
  # `issues` table has NULL even though it was originally pulled
  # from the server — `CodeMySpec.Issues.sync_disposition_to_remote/4`
  # used to treat NULL as "local-only, skip", silently dropping every
  # accept / dismiss / resolve push.
  #
  # Backfill: every existing NULL row was pulled from the server;
  # set them all to `true` so dispositions round-trip properly.
  # Newly created local issues get `false` via the Issue schema
  # default.
  def up do
    execute "UPDATE issues SET synced_from_server = 1 WHERE synced_from_server IS NULL;"
  end

  def down do
    :ok
  end
end
