defmodule CodeMySpec.Repo.Migrations.ARunIsKeyedOnItsCommitNotAFingerprint do
  use Ecto.Migration

  # 28d72f8a: a run is described by the commit it started and finished on
  # (`start_commit`, `start_tree_dirty`, `completed_commit`), and the promote
  # gate is the one place that asks whether it is current. The two fingerprint
  # columns were the other rule, and nothing reads them any more.
  #
  # `file_analyses` was `Analysis.Coverage`'s per-file freshness record, read
  # only by the dev freshness page. Both are gone.
  #
  # The CLI's SQLite schema is not touched: its `analysis_runs` never received
  # the commit columns either, and an unread column there costs nothing.
  def up do
    alter table(:analysis_runs) do
      remove :input_fingerprint
      remove :completed_fingerprint
    end

    drop table(:file_analyses)
  end

  # Columns and table come back empty; the values were derived and are not
  # restored.
  def down do
    alter table(:analysis_runs) do
      add :input_fingerprint, :string
      add :completed_fingerprint, :string
    end

    create table(:file_analyses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :file_id, references(:files, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :source, :string, null: false
      add :fingerprint, :string, null: false
      add :analyzed_at, :utc_datetime_usec, null: false
      add :run_id, references(:analysis_runs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:file_analyses, [:working_copy_id, :file_id, :source])
    create index(:file_analyses, [:working_copy_id, :source])
    create index(:file_analyses, [:file_id])
  end
end
