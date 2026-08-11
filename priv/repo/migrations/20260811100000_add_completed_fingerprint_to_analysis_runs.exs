defmodule CodeMySpec.Repo.Migrations.AddCompletedFingerprintToAnalysisRuns do
  use Ecto.Migration

  # `input_fingerprint` is stamped at enqueue, so comparing it to the tree now
  # cannot tell "the edit landed while this ran" from "the edit landed after it
  # finished". Those take opposite advice — one cannot be fixed by waiting and
  # one is fixed by nothing else — and the renderer was inferring which from the
  # run's duration, which misfires whenever a stop follows a long run closely
  # (7a7eed33).
  #
  # Nullable with no default: rows written before this have no answer, and
  # pretending they do would be worse than falling back to the old inference.
  def change do
    alter table(:analysis_runs) do
      add :completed_fingerprint, :string
    end
  end
end
