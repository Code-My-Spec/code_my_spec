defmodule CodeMySpec.Repo.Migrations.BackfillSyncedFromServer do
  use Ecto.Migration

  # `synced_from_server` was added in 20260518024054 as a nullable
  # boolean with no backfill. The flag drives the disposition-sync
  # guard in `CodeMySpec.Issues` — only `false` bypasses the remote
  # push, so NULL was supposed to mean "skip" too. But every issue
  # that predates this column came from a server sync, so treating
  # NULL as "local-only" silently dropped every disposition we made
  # on legacy rows. The next remote pull then re-wrote the local
  # state back to whatever the server still had.
  #
  # Backfill: every existing NULL row was pulled from the server;
  # set them all to `true` so dispositions round-trip properly.
  # Newly created local issues (post-migration, post-backfill) get
  # `false` via the Issue schema default.
  def up do
    execute "UPDATE issues SET synced_from_server = true WHERE synced_from_server IS NULL;"
  end

  def down do
    # No-op — the previous NULL state was a bug, not a meaningful
    # state worth restoring.
    :ok
  end
end
