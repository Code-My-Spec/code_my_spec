defmodule CodeMySpec.Repo.Migrations.AnalysisRunsKeepFindings do
  use Ecto.Migration

  def change do
    create table(:analysis_run_findings) do
      add :run_id, references(:analysis_runs, on_delete: :delete_all), null: false
      add :severity, :string, null: false
      add :source_type, :string
      add :source, :string, null: false
      add :file_path, :text
      add :line, :integer
      add :message, :text, null: false
      add :category, :string, null: false
      add :rule, :string
      add :metadata, :map
      add :test_name, :text
      add :criterion, :integer
      add :component_id, :uuid

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:analysis_run_findings, [:run_id])
    create index(:analysis_run_findings, [:file_path, :test_name])
    create index(:analysis_runs, [:project_id, :finished_at])
  end
end
