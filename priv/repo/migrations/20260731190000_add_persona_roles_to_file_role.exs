defmodule CodeMySpec.Repo.Migrations.AddPersonaRolesToFileRole do
  @moduledoc """
  Persona research artifacts become synced files.

  `PersonasChecker` used to read `summary.md` and `sources.md` off disk at
  evaluate time, which the light harness cannot do — the server holds no working
  copy. They are classified and validated at sync now, so the verdict travels
  with the file record.

  Two roles rather than one: each is validated by a different rule, and the
  checker reports them as separate gaps.

  SQLite stores `role` as a plain string, so there is no CLI counterpart to this
  — consistent with every earlier `file_role` addition.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'persona_summary'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'persona_sources'"
  end

  def down do
    :ok
  end
end
