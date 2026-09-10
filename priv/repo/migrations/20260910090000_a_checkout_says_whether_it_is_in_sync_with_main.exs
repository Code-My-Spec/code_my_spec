defmodule CodeMySpec.Repo.Migrations.ACheckoutSaysWhetherItIsInSyncWithMain do
  @moduledoc """
  Whether a checkout's work is on main, main's work is on it, and its tree is
  clean.

  The gate `code_on_running_copy` reads. It replaced a check that compared the
  story's implementation files across copies, which was insufficient for a case
  that happens on every project: promote a story, QA files an issue, fix the
  issue on the working copy. The files still exist on main — the old ones — and
  nothing forces the fix back across. Git knows exactly, and answering from git
  covers that case and every other one without depending on scans landing, on
  story-to-component linkage, or on file roles being classified right.

  ## Reported, not computed

  The server cannot run `git` here. A requirement graph is computed inside the
  channel process for a harness-served project, so shelling out to the machine
  that holds the disk would be the graph waiting on the connection it is being
  computed on. `CmsHarness.Sync.report_head_commit/2` already established the
  shape for this — "this machine can run `git` in the real checkout, so it
  does, on every sync" — and this is the same fact reported the same way.

  ## Nullable, and that is the point

  A copy that has never reported says nothing, which is different from a copy
  that reported "in sync". The first cannot be judged; the second can. Nothing
  is defaulted, so the gate can tell them apart and say which it is looking at.
  """
  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      # Commits this checkout has that main does not, and vice versa. A worktree
      # shares an object store with the checkout it was made from, so both are
      # answerable from the copy alone — `main..HEAD` and `HEAD..main` — with no
      # second root to find and no remote involved.
      add :commits_ahead_of_main, :integer
      add :commits_behind_main, :integer

      # Uncommitted tracked changes. Untracked files are excluded where this is
      # measured, for the reason `just refresh` already documents: refusing on
      # them means refusing essentially always, which is the same as not having
      # the check.
      add :tree_dirty, :boolean

      # When the three above were measured. A checkout that has gone quiet has
      # stale numbers, and a gate that cannot tell how old its evidence is will
      # eventually pass a story on a measurement from yesterday.
      add :git_state_at, :utc_datetime_usec
    end
  end
end
