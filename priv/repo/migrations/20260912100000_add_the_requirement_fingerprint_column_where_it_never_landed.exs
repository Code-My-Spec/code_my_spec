defmodule CodeMySpec.Repo.Migrations.AddTheRequirementFingerprintColumnWhereItNeverLanded do
  @moduledoc """
  Repairs a database that records `20260912070000` as applied and does not have
  the column it adds.

  Found on `code_my_spec_dev`: `schema_migrations` carries version
  20260912070000, stamped 2026-09-12 15:21, and
  `information_schema.columns` has no `requirements.inputs_fingerprint`. The
  version row committed and the DDL did not — the shape
  `reference_mix_ecto_migrate_loses_ddl_under_sandbox` describes, and the reason
  `mix ecto.rollback` cannot help: its down would drop an index that was never
  created and fail.

  A migrator will never revisit a version it has recorded, so nothing in the
  ordinary path fixes this. The next `just refresh` would apply the migration
  after it, restart the app, and every requirement read would raise
  `undefined_column` — on a graph that is read on every render and every stop
  hook.

  ## Why a repair migration rather than editing the ledger

  Deleting the row by hand fixes one database, in one place, if whoever is at
  the keyboard knows to. This fixes every database in that state, through the
  path that already runs on deploy, and says in the tree why it exists.

  `IF NOT EXISTS` on both statements, so a database where 20260912070000 landed
  properly — every test partition, and every environment that has not seen it
  yet — gets two no-op statements. Raw SQL because `alter table/add` has no
  conditional form; the column type and index name are copied from a database
  where the original applied correctly, so the result is identical either way.
  """

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE requirements ADD COLUMN IF NOT EXISTS inputs_fingerprint varchar(255)
    """

    execute """
    CREATE INDEX IF NOT EXISTS requirements_working_copy_id_inputs_fingerprint_index
      ON requirements (working_copy_id, inputs_fingerprint)
    """
  end

  # Deliberately a no-op. The column belongs to 20260912070000; this migration
  # only makes sure it is there. Dropping it on the way down would take a column
  # the earlier migration still claims to own, leaving the same split that made
  # this necessary, pointed the other way.
  def down, do: :ok
end
