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

  ## It names the database and does not manage it

  This used to create and migrate the partition too, and both of those shelled
  out to `mix` with an environment `Environments.clean_otp_env/0` had scrubbed
  `MIX_ENV` out of — so they ran against **dev**, the database every agent
  shares. A sibling truncate emptied it three times on 2026-08-13.

  Now it computes a name and nothing else.

  A database that does not exist is made by the run that wants it —
  `Mix.Tasks.Cms.CheckTestMigrations` creates and migrates it in-VM before the
  suite starts, for `mix test` and `mix spex` alike. That is not a return to the
  removed behaviour: the hazard was the child process and the environment it was
  given, and there is no child there to give one to. Nothing in *this* module
  reaches for DDL.

  It is worth being precise about what the removed version did, because the
  distinction is the whole design: a background process held DDL rights over a
  server it could be pointed at by an environment variable its parent forgot to
  set. What replaced it acts only on the database the running VM is already
  connected to, in `MIX_ENV=test`, which cannot be dev.
  """

  alias ClientUtils.Harness.Onboarding

  @doc """
  Environment for a `mix test` in `env` — the partition name, and nothing else.

  Returns `[]` for an environment with no working directory, which is the signal
  to run against whatever the project already uses.

  `build_env` is accepted and ignored. It mattered when this shelled out to
  `mix`; it is kept so callers do not have to change, and because a two-arity
  version of this would be the only difference between the harness's call site
  and a future one that needs it back.
  """
  @spec env(CodeMySpec.Environments.Environment.t(), [{String.t(), String.t()}], String.t() | nil) ::
          [{String.t(), String.t()}]
  def env(environment, build_env \\ [], source \\ nil)

  # Names the partition and nothing else. It used to create and migrate the
  # database too, and that is gone — see the note below `env/3`.
  def env(%{cwd: cwd}, _build_env, source) when is_binary(cwd) do
    [{"MIX_TEST_PARTITION", partition_for(cwd, source)}]
  end

  def env(_environment, _build_env, _source), do: []

  @doc """
  The partition name for a working copy — **read, never derived**.

  Delegates to `ClientUtils.Harness.Onboarding.resolve_partition!/2`, which returns
  what onboarding recorded and raises for a copy that has none, naming the command
  that fixes it.

  One path, deliberately. This used to digest the cwd here, with an identical
  digest in client_utils, so the analyzer ignored whatever onboarding wrote and the
  two agreed only because one algorithm had been written twice (acaf8035). A
  derive-on-miss fallback would have kept both alive for exactly the copies nobody
  had onboarded — silently, which is how the first pair survived.

  Short, stable, and derived from the absolute path — two worktrees of one
  project get different databases, and the same worktree gets the same one
  across restarts so the migrate is paid once.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    Onboarding.resolve_partition!(cwd)
  end

  @doc """
  The partition name for a working copy and one analyzer source.

  Each suite that can run concurrently gets its own; anything else keeps the
  shared one.

    <partition>    the interactive session's `mix test`
    <partition>s   the analyzer's spex run
    <partition>a   the analyzer's exunit run

  `Analysis` enqueues compiler, exunit and spex together, so exunit and spex
  suites run at the same time — and they ran against one database. Symptom
  (`bcad622d`): a sweep truncates before exunit and rows appear *during* it. 13
  committed `requirements` rows against an empty `projects` table, orphans of a
  project that no longer exists, and 17 failures in a file whose suite had
  passed 3,936/0 two minutes earlier. Failures that name files the session
  never touched and read exactly like real ones.

  **exunit moves too, and this paragraph used to argue it should not.** The
  original reasoning — "only spex moves; giving exunit a new name would orphan
  the database it has and force a fresh `ecto.create` + `ecto.migrate`, measured
  at 37.6s; spex pays that once and nothing else pays it at all" — costed the
  change correctly while answering a narrower question. It compared the
  analyzer's two suites to each other and missed the collision between the
  analyzer's exunit and **the agent's own interactive `mix test`**.

  Those shared a database, and not by accident: `mix cms.harness.onboard` writes
  `MIX_TEST_PARTITION` into `.claude/settings.local.json`'s `env` block so
  `resolve_partition!/2` can read it back, and Claude Code exports that block
  into the session. So an agent running `mix test` during a sweep got
  `bcad622d`'s exact shape, and it failed in the direction of "your branch broke
  these tests". The 37.6s is now knowingly paid, once per working copy.

  Ordering no longer matters the way it used to. This paragraph said that
  `Onboarding.databases/2` is "what tells anyone a database exists, and nothing
  creates them", so a partition used here and absent there was a database nobody
  was told to create — and that a release boundary between these two would be a
  window where the analyzer runs against a database no one has made. The run
  makes its own now, so a partition this invents is created the first time it is
  used, whatever `client_utils` happens to list.

  Deliberately a stopgap. The intent is to move `mix test` arbitration into our
  own analyzer — which already owns the run ledger and writes to Problems —
  rather than leaving client_utils to arbitrate it through an environment
  variable Claude Code happens to export. Nothing expensive should be built on
  this suffix.

  The suffix rather than a separate digest so the three stay visibly related —
  `h1a2b3c4d`, `h1a2b3c4ds` and `h1a2b3c4da` are recognisably one working copy
  when you are looking at a list of databases wondering which to drop.
  """
  @spec partition_for(String.t(), String.t() | nil) :: String.t()
  def partition_for(cwd, "spex"), do: partition_for(cwd) <> "s"
  def partition_for(cwd, "exunit"), do: partition_for(cwd) <> "a"
  def partition_for(cwd, _source), do: partition_for(cwd)
end
