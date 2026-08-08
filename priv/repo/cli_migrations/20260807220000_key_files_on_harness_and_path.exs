defmodule CodeMySpec.Repo.Migrations.KeyFilesOnHarnessAndPath do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `key_files_on_harness_and_path`.

  Same purpose: a path is unique per *working copy*, not per project, so two
  checkouts stop conflicting onto one row. The unique index moves from
  `(project_id, path)` to `(project_id, harness_id, path)`, which is what
  `conflict_target` names.

  ## What is not mirrored, and why

  The Postgres version also makes `harness_id` NOT NULL and flips the foreign
  key to `:delete_all`. Both are `modify`, which compiles to `ALTER COLUMN` —
  a statement SQLite does not have. The mirrored copy therefore raised
  `ALTER COLUMN not supported by SQLite3`, and because the migrator is a
  supervised child that is not a failed migration but a CLI that will not boot.

  Reproducing it on SQLite means rebuilding the table: create, copy, drop,
  rename. That is a real cost on a `files` table, and it buys a guarantee this
  deployment does not need in the same way. The NOT NULL exists because
  `ON CONFLICT` never matches a NULL, so a nullable column would turn every
  upsert from a harness-less writer into an insert — unbounded silent row
  growth. Deleting the orphans below removes the rows that could do that, and
  every writer now names its working copy, so nothing reintroduces them.

  The consequence is honest and worth stating: on SQLite the constraint is the
  application's rather than the database's. If a writer ever omits `harness_id`
  here, it inserts instead of failing. On Postgres it fails loudly, which is
  where that regression would be caught.
  """

  def up do
    # Projections with no owner. The next manifest rebuilds them, and there is
    # no honest answer to which copy produced them.
    execute("DELETE FROM files WHERE harness_id IS NULL")

    drop_if_exists unique_index(:files, [:project_id, :path])

    create unique_index(:files, [:project_id, :harness_id, :path])
  end

  def down do
    drop_if_exists unique_index(:files, [:project_id, :harness_id, :path])

    create unique_index(:files, [:project_id, :path])
  end
end
