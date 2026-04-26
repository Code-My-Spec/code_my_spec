defmodule CodeMySpec.Repo.Migrations.FixStoriesAccountIdType do
  use Ecto.Migration

  # The CLI `stories.account_id` column was originally declared `:integer`
  # (see 20251128000009_create_stories.exs) when the CLI didn't model
  # accounts. Server accounts moved to UUIDs on 2026-01-26
  # (20260126153450_change_accounts_to_uuid.exs) and the local
  # `CodeMySpec.Stories.Story` schema declares `field :account_id, :binary_id`.
  # Aligning the SQLite column type with the schema avoids relying on SQLite's
  # permissive type affinity (which has been storing UUIDs as TEXT in an
  # INTEGER-declared column on every other affected table).
  #
  # All existing rows have NULL `account_id` because a separate bug
  # (RemoteSync.upsert_story/2 does not `put_change(:account_id, ...)` and
  # Story.changeset/2 does not cast `:account_id`) caused account_id to be
  # dropped on every remote sync. After this migration + the code fix, a
  # fresh `sync_project` run will backfill the values.

  # Some local DBs are missing the `stories_account_id_index` even though
  # schema_migrations records 20251128000009 as applied (cause unclear —
  # likely a pre-cli_migrations-split rebuild). `drop_if_exists` lets this
  # recovery migration run on both healthy and divergent DBs.
  def up do
    drop_if_exists index(:stories, [:account_id])

    alter table(:stories) do
      remove :account_id
      add :account_id, :binary_id
    end

    create index(:stories, [:account_id])
  end

  def down do
    drop_if_exists index(:stories, [:account_id])

    alter table(:stories) do
      remove :account_id
      add :account_id, :integer
    end

    create index(:stories, [:account_id])
  end
end
