defmodule CodeMySpec.Repo.Migrations.ARunRecordsTheTreeItRanOn do
  use Ecto.Migration

  # The tree a clean run started on; a pass answers for it anywhere (story 1174).
  def change do
    alter table(:analysis_runs) do
      add :start_tree, :string
    end

    create index(:analysis_runs, [:project_id, :source, :start_tree])
  end
end
