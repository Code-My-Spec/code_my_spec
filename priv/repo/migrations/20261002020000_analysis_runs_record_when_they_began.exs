defmodule CodeMySpec.Repo.Migrations.AnalysisRunsRecordWhenTheyBegan do
  use Ecto.Migration

  # When the analyzer actually got a machine slot and started. `started_at` is
  # when the run was requested; a `:running` row with no `began_at` is queued
  # (bf627680).
  def change do
    alter table(:analysis_runs) do
      add :began_at, :utc_datetime_usec
    end
  end
end
