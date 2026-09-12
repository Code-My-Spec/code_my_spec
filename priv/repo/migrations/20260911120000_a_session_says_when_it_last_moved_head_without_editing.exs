defmodule CodeMySpec.Repo.Migrations.ASessionSaysWhenItLastMovedHeadWithoutEditing do
  @moduledoc """
  When a session last ran a Bash command that can move `HEAD` or rewrite the
  worktree without going through Write/Edit — `git rebase`, `pull`, `merge`,
  `checkout`, `reset`, `cherry-pick`, `stash pop`/`apply`.

  `Validation.narrow_to_attributed/4` reads it to stop trusting a small
  mtime-dirty set with no PostToolUse attribution: that combination used to
  mean "wrote through something other than Write/Edit" (a spex, a direct
  evaluator) and was kept whole. A `git rebase` that pulls in one or two
  already-committed files produces the identical signature — a few dirty
  files, zero attribution — and got the same pass, crediting one session with
  another session's already-pushed work (f8af8bf2). This field is the
  difference: a rewrite recorded after the task started means the dirty files
  may be inherited history rather than this turn's writes.

  Nullable, because a session that has never run one of these commands is a
  different fact from a session whose signal did not persist.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :git_rewrite_at, :utc_datetime_usec
    end
  end
end
