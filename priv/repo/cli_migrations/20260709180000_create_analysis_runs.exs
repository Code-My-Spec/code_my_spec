defmodule CodeMySpec.Repo.Migrations.CreateAnalysisRuns do
  use Ecto.Migration

  def change do
    create table(:analysis_runs) do
      add :source, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false
      add :input_fingerprint, :string
      add :args, :map
      add :stats, :map
      add :output, :text
      add :exit_status, :integer
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:analysis_runs, [:project_id, :source, :status])
    create index(:analysis_runs, [:project_id, :source, :input_fingerprint])
  end
end
