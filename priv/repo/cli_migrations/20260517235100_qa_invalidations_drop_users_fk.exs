defmodule CodeMySpecCli.Repo.Migrations.QaInvalidationsDropUsersFk do
  use Ecto.Migration

  # `qa_invalidations.invalidated_by_user_id` was created with
  # `references(:users, on_delete: :nilify_all)`, but the CLI SQLite
  # database has no `users` table — only `client_users`. The FK is
  # cosmetic on the local side (no auth, `invalidated_by_user_id` is
  # always nil), but SQLite enforces the constraint at insert time and
  # crashes with `no such table: main.users` even when the value is
  # NULL.
  #
  # Drop the FK constraint here so local invalidate works. The SaaS
  # Postgres migration keeps the FK; this only affects the CLI repo.
  def up do
    # SQLite has no DROP CONSTRAINT — recreate the table without the FK.
    rename table(:qa_invalidations), to: table(:qa_invalidations_old)

    create table(:qa_invalidations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :qa_attempt_id,
          references(:qa_attempts, type: :binary_id, on_delete: :delete_all),
          null: false

      # Plain integer column on the CLI side. No FK because the
      # referenced `users` table doesn't exist locally.
      add :invalidated_by_user_id, :integer
      add :reason, :string, null: false
      add :invalidated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute "INSERT INTO qa_invalidations SELECT * FROM qa_invalidations_old"
    drop table(:qa_invalidations_old)

    create unique_index(:qa_invalidations, [:qa_attempt_id])
  end

  def down do
    :ok
  end
end
