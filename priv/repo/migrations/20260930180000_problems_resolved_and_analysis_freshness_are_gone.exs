defmodule CodeMySpec.Repo.Migrations.ProblemsResolvedAndAnalysisFreshnessAreGone do
  use Ecto.Migration

  # 28d72f8a: analyzer findings are the promote gate's job, so the story
  # requirement `problems_resolved` has no definition. Its stored rows would be
  # served until their entity happened to recompute; deleting them cascades
  # their edges. No agent or session task names it.
  #
  # `analysis_freshness` was the projection the graph read run freshness from.
  # The graph now reads the latest completed run, so nothing reads the table.
  def up do
    for table <- ~w(requirements shadow_requirements) do
      execute("DELETE FROM #{table} WHERE name = 'problems_resolved'")
    end

    drop table(:analysis_freshness)
  end

  # The requirement rows come back on the next graph pass if the definition
  # does; the freshness rows were a projection and are not restored.
  def down do
    create table(:analysis_freshness) do
      add :working_copy_id, references(:working_copies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source, :string, null: false
      add :fresh, :boolean, null: false
      add :run_id, :bigint
      add :fresh_at, :naive_datetime
      add :staled_at, :naive_datetime
      add :staled_by, :string

      timestamps()
    end

    create unique_index(:analysis_freshness, [:working_copy_id, :source])
  end
end
