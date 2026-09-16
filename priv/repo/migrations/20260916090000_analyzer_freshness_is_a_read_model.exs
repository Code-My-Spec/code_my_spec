defmodule CodeMySpec.Repo.Migrations.AnalyzerFreshnessIsAReadModel do
  use Ecto.Migration

  # "Is this analyzer's last run current for today's code" is derived, and it
  # was being derived on every single read.
  #
  # `Analysis.fresh?/2` calls `Fingerprint.current/2`, which calls
  # `Files.list_files/1` — the whole file table for the checkout, ~5,100 rows —
  # and hashes the subset feeding that source. `fresh_sources/2` does it once
  # for all four. The promote gate asks on every attempt;
  # `Preloader.analysis_freshness/2` asks on every graph pass and is the only
  # reason a narrow per-entity load still has to read the whole file table.
  #
  # None of that is a question about now. It is a question about two events that
  # already happened: a run finished, and a file it reads changed. Which of
  # those came last is the entire answer.
  #
  # ## Its own table, because it is a read model
  #
  # Not a column on `working_copies`. That row is a write model — a checkout, a
  # device, a root, a designation — and freshness is a projection of runs and
  # files. Putting it there makes the table two things at once and means the
  # read side cannot be rebuilt without touching the write side.
  #
  # ## Absence means unknown, not stale
  #
  # A row is never deleted, only flipped, so "no row" unambiguously means this
  # copy and source have never been projected — and the reader falls back to the
  # fingerprint comparison rather than guessing. That is what makes this safe to
  # roll out without a backfill, and it is the same reason the comparison stays
  # in the code as a rebuild path: a git checkout or a branch switch changes
  # files without emitting anything, and a stale *clean* row is a false pass,
  # which is the direction that costs correctness.
  #
  # Per working copy, and `RunsRepository.latest_completed_run/2` already says
  # why: "freshness is a question about one working copy's tree. Unscoped, the
  # latest run of *any* checkout answered it, and its fingerprint is computed
  # over different files."
  def change do
    create table(:analysis_freshness) do
      add :working_copy_id, references(:working_copies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source, :string, null: false
      add :fresh, :boolean, null: false

      # What made it fresh, so a reader can say which run answered rather than
      # only that one did.
      add :run_id, :bigint
      add :fresh_at, :naive_datetime

      # And what took it away. A source that is stale with no explanation is the
      # shape that cost sixteen minutes to diagnose the last time this
      # neighbourhood was touched.
      add :staled_at, :naive_datetime
      add :staled_by, :string

      timestamps()
    end

    create unique_index(:analysis_freshness, [:working_copy_id, :source])
  end
end
