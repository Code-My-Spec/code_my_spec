defmodule CodeMySpec.Repo.Migrations.KeyFilesOnHarnessAndPath do
  use Ecto.Migration

  @moduledoc """
  A path is unique per *working copy*, not per project.

  `UNIQUE (project_id, path)` was the last thing keeping two checkouts from
  coexisting. Scoping the queries stopped one sync deleting files only the other
  had, but the second checkout's upsert still conflicted onto the first's row
  and updated it — `harness_id` is not in the `on_conflict` replace list, so the
  row stayed the first's and the second appeared to have no such file at all.

  ## `harness_id` becomes NOT NULL, and that is the point

  `conflict_target` has to name a unique index, so it now includes `harness_id`
  — and `ON CONFLICT` never matches a NULL. Left nullable, every upsert from a
  harness-less writer would insert a duplicate instead of updating one, which is
  a worse failure than the one being fixed: silent unbounded row growth rather
  than a visible collision.

  So every writer names its working copy. That is true of all of them: the
  channel has its harness, and the local app serves exactly one checkout and
  simply never had to say which. Rows that predate the column are deleted rather
  than assigned — they are projections, the next scan rebuilds them, and there
  is no honest answer to which copy produced them.

  ## `on_delete` flips to `:delete_all`

  The previous migration used `:nilify_all`, reasoning that a row whose harness
  had gone should be visibly unowned rather than silently absent. NOT NULL takes
  that option away — nilifying would violate the constraint the moment an
  operator deleted a harness. `:delete_all` is right anyway once the column is
  mandatory: these rows are a projection of one checkout, and a checkout nobody
  is serving has no observations to keep.
  """

  def up do
    # Projections with no owner. The next manifest rebuilds them.
    execute("DELETE FROM files WHERE harness_id IS NULL")

    drop unique_index(:files, [:project_id, :path])

    alter table(:files) do
      modify :harness_id, references(:harnesses, type: :binary_id, on_delete: :delete_all),
        null: false,
        from: references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:files, [:project_id, :harness_id, :path])
  end

  def down do
    drop unique_index(:files, [:project_id, :harness_id, :path])

    alter table(:files) do
      modify :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: references(:harnesses, type: :binary_id, on_delete: :delete_all)
    end

    create unique_index(:files, [:project_id, :path])
  end
end
