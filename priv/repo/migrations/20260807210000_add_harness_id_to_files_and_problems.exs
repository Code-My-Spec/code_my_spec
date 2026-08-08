defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToFilesAndProblems do
  use Ecto.Migration

  @moduledoc """
  The grain change itself: a file belongs to the working copy it was scanned
  from, not to the project.

  Until now two checkouts of one project wrote the same rows and each sync
  deleted what the other had just written — `FileSync.reconcile/2` is a full
  reconcile, so the losing checkout's files were removed on every scan. The
  requirement graph computed from those rows then described neither checkout.

  ## Existing rows are deleted, not backfilled

  Files and problems are *projections of a working copy*. Nothing is authored
  here: every row is re-derived from a scan, and a harness sends its whole
  manifest on join. So the honest answer to "which working copy observed these"
  for rows that predate the question is to stop claiming to know, and let the
  next sync say.

  The alternative — mint a harness per project and assign its rows to it —
  invents an owner no working copy has an id file for. The first real checkout
  would present no id, be minted a *second* harness, and the backfilled rows
  would sit under one nothing ever joins as. Repairing that needs a claim step
  whose only job is to undo a fiction this migration would have introduced.

  Cost of deleting is one resync, which happens on the next join anyway. Cost of
  being wrong about an invented owner is a project whose files belong to a
  harness that does not exist.

  `on_delete: :nilify_all` rather than `:delete_all`. Deleting a harness is an
  operator saying "I am done with that checkout", not "destroy what it
  observed" — and a row whose harness has gone is visibly unowned rather than
  silently absent.
  """

  def up do
    # Projections, and stale ones: they describe a checkout nobody can now
    # identify. The next manifest replaces them wholesale.
    execute("DELETE FROM problems")
    execute("DELETE FROM files")

    alter table(:files) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:problems) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:files, [:harness_id])
    create index(:files, [:project_id, :harness_id])
    create index(:problems, [:harness_id])
    create index(:problems, [:project_id, :harness_id])
  end

  def down do
    drop index(:problems, [:project_id, :harness_id])
    drop index(:problems, [:harness_id])
    drop index(:files, [:project_id, :harness_id])
    drop index(:files, [:harness_id])

    alter table(:problems) do
      remove :harness_id
    end

    alter table(:files) do
      remove :harness_id
    end
  end
end
