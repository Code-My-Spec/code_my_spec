defmodule CodeMySpec.Repo.Migrations.AddTheRequirementFingerprintColumnWhereItNeverLanded do
  @moduledoc """
  Adds `requirements.inputs_fingerprint`, which its own migration never got to
  add anywhere.

  Story 1020's migration was written as `20260912070000`. A migration on `main`
  had already taken that version — `drop_the_orphaned_tools_seen_at` — and the
  two met in a merge. A version is recorded once, so whichever of the pair ran
  is the only one that ever runs: the ledger says `20260912070000` is applied
  and the other file's DDL is unreachable, permanently and silently.

  `drop_the_orphaned_tools_seen_at` is the one that won, measured on both
  `code_my_spec_dev` and the test partition: `working_copies.tools_seen_at` is
  gone from both and `requirements.inputs_fingerprint` was on neither. So the
  column this adds had never been created, while every graph read was about to
  ask for it.

  `mix ecto.rollback` is no help — its down would drop an index that was never
  created — and renumbering the losing file does not help either, because the
  version it collided with stays recorded. So the losing file is deleted and
  its work moves here, under a version of its own.

  `IF NOT EXISTS` on both statements, so this is two no-ops against a database
  where the column somehow exists. The type and index name are taken from a
  database where the original DDL had been applied, so both routes end at the
  same schema.
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
