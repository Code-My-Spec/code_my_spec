defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToAnalysisRuns do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_harness_id_to_analysis_runs`.

  Same purpose: a run belongs to a working copy, so the lookup on submit and
  the sweep on join can stop crossing between checkouts of one project. See the
  Postgres copy for the measurement that prompted it.

  `references/2` is deliberately not used here. SQLite enforces foreign keys
  only with `PRAGMA foreign_keys` on, so the constraint would be decorative,
  and adding one to an existing table is a table rebuild for a guarantee this
  deployment does not get. The column and the index are what the queries need.
  """

  def change do
    alter table(:analysis_runs) do
      add :harness_id, :binary_id
    end

    create index(:analysis_runs, [:project_id, :harness_id, :status])
  end
end
