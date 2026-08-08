defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToFilesAndProblems do
  use Ecto.Migration

  @moduledoc """
  The grain change itself: a file belongs to the working copy it was scanned
  from, not to the project.

  Until now two checkouts of one project wrote the same rows and each sync
  deleted what the other had just written — `FileSync.reconcile/2` is a full
  reconcile, so the losing checkout's files were removed on every scan. The
  requirement graph computed from those rows then described neither checkout.

  Nullable, and deliberately so. A `NOT NULL` column would need every existing
  row assigned in this migration, and there is no correct answer available here:
  the database cannot know which working copy synced them. `NULL` means
  "recorded before harnesses existed", which is a true statement about those
  rows and one the application can act on — the first harness to join adopts
  them, because in the single-checkout case every install is in today, it *is*
  the working copy they came from.

  Doing the backfill in the application rather than in SQL also avoids inventing
  UUIDs in two dialects: Postgres has `gen_random_uuid()` and SQLite does not,
  and a data migration that differs between the two is a data migration nobody
  can reason about.

  `on_delete: :nilify_all` rather than `:delete_all`. Deleting a harness is an
  operator saying "I am done with that checkout", not "destroy what it observed"
  — and orphaned rows are recoverable by the adoption path, where deleted ones
  are simply gone.
  """

  def change do
    alter table(:files) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:problems) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    # Every read of a working copy's files goes through this pair.
    create index(:files, [:harness_id])
    create index(:files, [:project_id, :harness_id])
    create index(:problems, [:harness_id])
    create index(:problems, [:project_id, :harness_id])
  end
end
