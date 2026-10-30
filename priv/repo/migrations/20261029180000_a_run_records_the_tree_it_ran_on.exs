defmodule CodeMySpec.Repo.Migrations.ARunRecordsTheTreeItRanOn do
  @moduledoc """
  Adds `analysis_runs.start_tree`: the git tree of the commit a clean run
  started on. A pass answers for that tree from any copy or commit (story
  1174). Nullable, no default: a run started dirty, or reported by a harness
  that predates it, has none and is never reused.
  """

  use Ecto.Migration

  def change do
    alter table(:analysis_runs) do
      add :start_tree, :string
    end

    create index(:analysis_runs, [:project_id, :source, :start_tree])
  end
end
