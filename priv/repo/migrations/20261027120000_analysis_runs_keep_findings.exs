defmodule CodeMySpec.Repo.Migrations.AnalysisRunsKeepFindings do
  use Ecto.Migration

  def change do
    alter table(:analysis_runs) do
      add :findings, :map
    end

    create_if_not_exists index(:analysis_runs, [:project_id, :finished_at])
  end
end
