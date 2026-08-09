defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToAnalysisRuns do
  use Ecto.Migration

  @moduledoc """
  A run belongs to a working copy, not to a project.

  Runs were scoped by `project_id` alone, and three worktrees of one repo are
  one project. So `fail_running/2` — which closes in-flight runs when a harness
  joins, on the reasoning that they belonged to a connection that has gone —
  closed the *other* working copies' runs too. Their analyzers then answered a
  row that was no longer `:running`, `get_running_run/2` returned nil, and the
  result came back `unknown_run`.

  With more than one checkout attached, that is not a race: a join from any
  harness kills every other harness's in-flight run, and joins are frequent.
  Measured on this machine: 285 results sent, 0 accepted, 161 `unknown_run`.
  `bdd_specs_passing` was unsatisfiable for every story in the project, because
  the only evidence that can satisfy it is an analyzer result and none could
  ever be recorded.

  Nullable, and no default: rows written before this cannot be attributed to a
  working copy, and guessing one would be worse than admitting it. They are
  `:running` forever from the scoped queries' point of view, which the retention
  sweep clears.
  """

  def change do
    alter table(:analysis_runs) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :delete_all)
    end

    # The lookup on submit and the sweep on join both filter project + harness +
    # status; the retention sweep filters project + source.
    create index(:analysis_runs, [:project_id, :harness_id, :status])
  end
end
