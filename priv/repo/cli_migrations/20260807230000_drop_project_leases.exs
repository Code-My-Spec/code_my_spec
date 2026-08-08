defmodule CodeMySpec.Repo.Migrations.DropProjectLeases do
  use Ecto.Migration

  @moduledoc """
  The lease has nothing left to protect.

  It existed for one reason, stated in its own moduledoc: files, components and
  problems were per-project rows, so two harnesses pointed at one project each
  synced their own working copy into that single set and each sync removed what
  the other had just written.

  Files and problems are keyed on the harness now. A reconcile only ever touches
  the rows its own working copy produced, so two checkouts writing at once is
  ordinary rather than corrupting — and refusing the second one was the last
  thing standing between the grain change and what it was for.

  Two harness *processes* on one working copy still need refusing, but not over
  this: they read the same disk, so their manifests agree. What they cannot
  share is `_build` — two `mix test` runs in one build tree corrupt it into
  reporting failures that are not in the code. That is
  `Analysis.register_executor/1`, a registry entry keyed on the harness and
  held for the life of the channel. No table, no advisory lock, no expiry.

  The table goes with `CodeMySpec.Leases`, `Leases.Session` and
  `Leases.ProjectLease`. Nothing reads it: the row was never the authority, only
  a label written after the lock so a refusal could name which checkout to go
  and stop.
  """

  def up do
    drop table(:project_leases)
  end

  def down do
    create table(:project_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, :binary_id, null: false
      add :holder_label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_leases, [:project_id])
  end
end
