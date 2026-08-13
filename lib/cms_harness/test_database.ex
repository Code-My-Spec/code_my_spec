defmodule CmsHarness.TestDatabase do
  @moduledoc """
  A test database per working copy, so the analyzer's answer is about the tree
  it was pointed at.

  ## The failure this exists to stop

  `mix test` uses whatever database `config/test.exs` names, and on a machine
  running several agents that is one database shared by every checkout.
  Whichever one migrated last wins and the others inherit its schema.

  Measured here, same commit, same suite: **36 failures** on the shared database
  and **1** on its own. The whole difference was one column — `conversations.type`,
  `NOT NULL`, added by a branch this checkout does not have. Every insert on this
  branch then died, and the stop hook reported ~25 failures across four test
  files as though this branch had broken them.

  That is worse than slow. The analyzer's verdict is what the harness is *for*,
  and an agent that believes it will start repairing code that was never broken.
  Nothing in the output distinguishes "your code is wrong" from "this database is
  not yours".

  ## Per working copy, not per project

  Two worktrees of one project is the ordinary case — a branch each — and they
  need different schemas at the same time, which is exactly what a project-keyed
  name would deny them. So the partition is derived from the absolute path of the
  working copy.

  ## Degrading rather than guessing

  Setting `MIX_TEST_PARTITION` only isolates a project whose `config/test.exs`
  reads it. Where it does (the Phoenix default, and this repo), the database has
  to exist, so this creates and migrates it first. Where it does not, the name is
  unchanged and this is a no-op.

  If either step fails — no Ecto, no database server, a project that does not
  work this way — no partition is set and the run proceeds exactly as it did
  before. An analyzer that refused to run because it could not manage a database
  would be a worse failure than the one this fixes.

  ## Staying migrated

  Isolation alone is not enough: a database of one's own that is a schema behind
  produces the same indistinguishable failures as a shared one. The migrate is
  therefore keyed on the set of migration files, not on the harness's lifetime,
  so a tree that gains migrations while the harness is running picks them up.
  """

  require Logger

  alias CodeMySpec.Environments

  @doc """
  Environment for a `mix test` in `env`, isolating its database when it can.

  Returns `[]` when isolation is not available, which is the signal to run
  against whatever the project already uses.

  `build_env` is the caller's `MIX_BUILD_PATH`, passed on to the `mix`
  invocations this makes. Without it they take the default path — `_build/test`,
  the tree the agent's own `mix test` writes — and `ecto.create`/`ecto.migrate`
  compile the project before running, so provisioning the analyzer's database
  compiled into the agent's tree. That is the collision `AnalyzerEnv` exists to
  prevent, described in its own moduledoc: modules vanish from under a running
  suite and return as "module X is not available" for a module that plainly
  exists.

  It is rare — `ensure_once/3` memoises per partition per migration set — but it
  fires on a fresh working copy and after a rebase that brings migrations, which
  is exactly when the agent is likely to be compiling too.
  """
  @spec env(Environments.Environment.t(), [{String.t(), String.t()}], String.t() | nil) ::
          [{String.t(), String.t()}]
  def env(environment, build_env \\ [], source \\ nil)

  # Names the partition and nothing else. It used to create and migrate the
  # database too, and that is gone — see the note below `env/3`.
  def env(%{cwd: cwd}, _build_env, source) when is_binary(cwd) do
    [{"MIX_TEST_PARTITION", partition_for(cwd, source)}]
  end

  def env(_environment, _build_env, _source), do: []

  # No provisioning, and no truncation. Both used to live here and both shelled
  # out to `mix` — `ecto.create`, `ecto.migrate`, and a script that truncated
  # every table in whichever repo it reached.
  #
  # `MIX_ENV` was scrubbed out of the child environment by
  # `Environments.clean_otp_env/0`, so all three ran against **dev**: the
  # migrate applied a migration nobody ran there, and the truncate emptied
  # `code_my_spec_dev` three times on 2026-08-13.
  #
  # Fixing the env would have made them safe. Removing them makes them
  # impossible, which is the property worth having: no code path in this
  # project may migrate or truncate a database. `Mix.Tasks.Cms.CheckTestMigrations`
  # already set that precedent — "a refusal rather than an alias that migrates" —
  # and this module was the thing violating it.
  #
  # What survives is the partition NAME, which is pure string computation and
  # touches nothing. `config/test.exs` already derives a per-worktree database
  # on its own; this only adds the spex suffix so exunit and spex do not share
  # one. A database that does not exist now fails the run loudly with
  # "database does not exist", which a human answers with
  # `MIX_ENV=test mix ecto.create`.

  # The pre-run truncate lived here and is gone. See `CmsHarness.Analysis`
  # for why: it cleaned up a sandbox escape that the evidence does not support,
  # and what it actually did was empty `code_my_spec_dev` three times on
  # 2026-08-13 because `MIX_ENV` was scrubbed out of its child environment.
  #
  # Provisioning below still shells out to mix, and still needs that env to
  # survive — `cmd_opts/2` is what makes sure it does.


  @doc """
  The partition name for a working copy.

  Short, stable, and derived from the absolute path — two worktrees of one
  project get different databases, and the same worktree gets the same one
  across restarts so the migrate is paid once.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    digest =
      cwd
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "h#{digest}"
  end

  @doc """
  The partition name for a working copy and one analyzer source.

  spex gets its own; everything else keeps the shared one.

  `Analysis` enqueues compiler, exunit and spex together, so exunit and spex
  suites run at the same time — and they ran against one database. Symptom
  (`bcad622d`): a sweep truncates before exunit and rows appear *during* it. 13
  committed `requirements` rows against an empty `projects` table, orphans of a
  project that no longer exists, and 17 failures in a file whose suite had
  passed 3,936/0 two minutes earlier. Failures that name files the session
  never touched and read exactly like real ones.

  Only spex moves. Giving exunit a new name would orphan the database it has
  and force a fresh `ecto.create` + `ecto.migrate`, measured at 37.6s; spex
  pays that once and nothing else pays it at all.

  The suffix rather than a separate digest so the two stay visibly related —
  `h1a2b3c4d` and `h1a2b3c4ds` are recognisably one working copy when you are
  looking at a list of databases wondering which to drop.
  """
  @spec partition_for(String.t(), String.t() | nil) :: String.t()
  def partition_for(cwd, "spex"), do: partition_for(cwd) <> "s"
  def partition_for(cwd, _source), do: partition_for(cwd)
end
