defmodule CodeMySpec.Repo.Migrations.AddCredoCheckToFileRole do
  @moduledoc """
  Credo check sources become synced files.

  `.code_my_spec/credo_checks/**/*.ex[s]` fell between two classifiers —
  `classify_code/1` claims only `lib/` and `test/`, `classify_docs/1` only `.md`
  — so they never synced. `SpexBoundaryChecker` therefore had to stat them, and
  could not run at all on a server with no working copy.

  SQLite stores `role` as a plain string, so there is no CLI counterpart.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'credo_check'"
  end

  def down do
    :ok
  end
end
