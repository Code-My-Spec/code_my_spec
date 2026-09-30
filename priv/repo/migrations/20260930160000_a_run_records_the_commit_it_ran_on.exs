defmodule CodeMySpec.Repo.Migrations.ARunRecordsTheCommitItRanOn do
  @moduledoc """
  Adds `analysis_runs.start_commit`, `start_tree_dirty` and `completed_commit`:
  the commit the harness's working copy was at when the analyzer started,
  whether its tree had uncommitted changes then, and the commit when it
  finished. A run whose tree moved while it ran shows as two different commits.

  Nullable, no defaults: a run no harness reported a commit for has none.
  """

  use Ecto.Migration

  def change do
    alter table(:analysis_runs) do
      add :start_commit, :string
      add :start_tree_dirty, :boolean
      add :completed_commit, :string
    end
  end
end
