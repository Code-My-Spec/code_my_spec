defmodule CodeMySpec.Repo.Migrations.ASharedBoxBelongsToNoAccount do
  @moduledoc """
  A device may belong to no account.

  `account_id` was `null: false`, which quietly asserted that every machine is
  somebody's. A shared development box is not: several people work on it, it
  holds no project of its own, and forcing it to claim an account would attach
  it to whichever one happened to announce first.

  Nullable is the honest shape. "This machine belongs to nobody" and "we do not
  know whose this is" are the same row, and both are true of a shared box —
  the same reasoning that keeps `working_copies.device_id` nullable rather than
  inventing a machine for a checkout that never reported one.

  Devices stay account-*scoped* where an account exists. This widens what may be
  stored, not who may read it.

  ## Why this is not the Postgres copy

  Relaxing a constraint is still `ALTER COLUMN`, which SQLite does not have, so
  the table is rebuilt without it.

  The order matters. `working_copies.device_id` references this table, and
  SQLite rewrites a referencing FK to follow a `RENAME` — renaming `devices`
  out of the way would silently repoint `working_copies` at the temporary
  table. Building the replacement under its own name, copying, dropping, and
  renaming *into* place leaves that FK naming `devices` throughout.
  """

  use Ecto.Migration

  def up do
    create table(:devices_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hostname, :text
      add :label, :text
      add :kind, :string

      # The whole point of this migration.
      add :account_id, :binary_id

      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    execute("""
    INSERT INTO devices_new (id, hostname, label, kind, account_id, last_seen_at,
                             inserted_at, updated_at)
    SELECT id, hostname, label, kind, account_id, last_seen_at,
           inserted_at, updated_at
    FROM devices
    """)

    # Empty at this point on any database that reaches here in one pass, so the
    # implicit DELETE that a DROP runs against `working_copies`' foreign key
    # touches nothing.
    drop table(:devices)
    rename table(:devices_new), to: table(:devices)

    create index(:devices, [:account_id])
  end

  def down do
    # Irreversible in general: a shared box has no account to put back, so
    # anything that announced without one would have to be invented or deleted.
    # Rolling back is a decision about that data, not a mechanical step.
    execute("DELETE FROM devices WHERE account_id IS NULL")
  end
end
