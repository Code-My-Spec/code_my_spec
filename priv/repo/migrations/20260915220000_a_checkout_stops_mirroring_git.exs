defmodule CodeMySpec.Repo.Migrations.ACheckoutStopsMirroringGit do
  use Ecto.Migration

  # `commits_ahead_of_main`, `commits_behind_main`, `tree_dirty` and
  # `git_state_at` are a property of a git repository, not of this domain.
  #
  # Nothing decided on them. `Promotion.promoted/2` answers
  # `code_on_running_copy` from the story's own `promoted_version` stamp, and
  # the promote gate measures git live by running it — `git merge --ff-only` is
  # both its precondition and its merge. These columns were a second, staler
  # copy of an answer we can always ask for, and `Sync` recorded them
  # disagreeing: "at 06:01 git said `ahead=0 behind=0` and the row still said
  # `ahead=3`".
  #
  # They were also expensive. `Freshness.story/2` hashed them into every story's
  # fingerprint, so one keystroke in any checkout reconsidered every story in
  # the project, and `record_git_state/2` announced a graph change on every sync
  # — a pass and a preload per checkout to discover nothing had moved. Measured
  # on dev: `working_copies` took 22 distinct digests in an hour while every
  # other shared input took between 2 and 6.
  #
  # Irreversible on purpose. `down/0` could restore the columns but not the
  # values, and a checkout reports its git state on every sync, so what a
  # rollback would actually recreate is four null columns that fill themselves
  # in — not the state this dropped.
  def up do
    alter table(:working_copies) do
      remove :commits_ahead_of_main
      remove :commits_behind_main
      remove :tree_dirty
      remove :git_state_at
    end
  end

  def down do
    alter table(:working_copies) do
      add :commits_ahead_of_main, :integer
      add :commits_behind_main, :integer
      add :tree_dirty, :boolean
      add :git_state_at, :utc_datetime_usec
    end
  end
end
