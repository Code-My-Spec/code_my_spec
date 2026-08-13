defmodule CmsHarness.TestDatabaseTest do
  @moduledoc """
  Which database the analyzer's `mix test` runs against.

  The property under test is isolation between checkouts. Two worktrees of one
  project is the ordinary case — a branch each — and they need different schemas
  at the same time. Sharing one database means whichever migrated last decides
  what the others' tests see, and the analyzer reports the difference as failures
  belonging to whoever asked.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.TestDatabase

  describe "partition_for/1" do
    test "two checkouts of one project get different databases" do
      main = TestDatabase.partition_for("/src/app")
      worktree = TestDatabase.partition_for("/src/app/.claude/worktrees/feature")

      refute main == worktree,
             "a worktree needs its own schema; sharing is how one branch's " <>
               "migration becomes another branch's test failures"
    end

    test "the same checkout gets the same database across restarts" do
      assert TestDatabase.partition_for("/src/app") == TestDatabase.partition_for("/src/app")
    end

    test "spellings of one path agree, so a harness does not migrate twice" do
      assert TestDatabase.partition_for("/src/app") == TestDatabase.partition_for("/src/app/")

      assert TestDatabase.partition_for("/src/app") ==
               TestDatabase.partition_for("/src/other/../app")
    end

    test "it is a usable database suffix" do
      assert TestDatabase.partition_for("/src/app") =~ ~r/^h[0-9a-f]{8}$/,
             "this is concatenated onto a database name — it has to be short and plain"
    end
  end

  describe "the reset's mix invocation" do
    # `--no-compile` does not imply `--no-deps-check`, and the deps check
    # refuses on a lock mismatch — the state a rebase leaves between bringing a
    # new mix.lock and the next `mix deps.get`. Five resets on this machine
    # refused with "lock mismatch: the dependency is out of date", four of them
    # inside ten minutes of rebasing, so the truncate that eb75952f runs before
    # every sweep was not running at all in exactly the window where a rebase
    # makes residue most likely (bcad622d).
    #
    # Verified against mix rather than assumed: with an empty deps path,
    # `mix run --no-compile` answers "Unchecked dependencies for environment
    # test" and the same command with `--no-deps-check` gets past it.
    test "it skips the deps check, which no-compile does not do for it" do
      assert "--no-deps-check" in CmsHarness.TestDatabase.reset_args()
    end

    # The most expensive defect this file has held, and it was invisible.
    #
    # `Environments.clean_otp_env/0` sets MIX_ENV to nil alongside the release
    # variables, and the caller appended it AFTER `{"MIX_ENV", "test"}` — so the
    # scrub won and the child got no MIX_ENV at all. `mix` then defaulted to
    # dev, and `truncate_script/0` — which truncates every table in whichever
    # repo it finds — ran against `code_my_spec_dev`, the database every agent
    # on the machine shares. It emptied it twice on 2026-08-13.
    #
    # Nothing in the log said so: `report_rows_removed/2` names the partition it
    # was asked for rather than the database it reached, so it reported
    # "removed 101972 committed row(s) from the analyzer database h789652af"
    # while dev was the one going empty.
    #
    # Asserted on the env rather than on the call site, because the way back to
    # the bug is someone re-hand-rolling the concatenation. `merge_clean_env/1`
    # already documents the rule — "it is wrong for MIX_ENV: a caller that named
    # one meant it" — and this is what makes ignoring it fail loudly.
    test "MIX_ENV survives the OTP scrub, so the truncate cannot reach dev" do
      env = CmsHarness.TestDatabase.cmd_opts("h789652af")[:env]

      assert {"MIX_ENV", "test"} in env,
             "MIX_ENV was scrubbed out of the reset's environment. The child mix will " <>
               "default to dev and the truncate will empty the shared development " <>
               "database instead of the analyzer partition."

      refute {"MIX_ENV", nil} in env,
             "the scrub is still unsetting MIX_ENV after the caller set it"

      assert {"MIX_TEST_PARTITION", "h789652af"} in env,
             "without the partition the reset targets the unpartitioned test database, " <>
               "which every other checkout is also using"

      # The scrub still has to do its own job — this is not a licence to skip it.
      assert {"RELEASE_ROOT", nil} in env,
             "release variables must still be cleared, or a child mix launched from a " <>
               "Burrito binary cannot boot at all"
    end

    # Nothing is built here, so a tree that has never been compiled must not be
    # compiled by the reset — that is the collision AnalyzerEnv exists to
    # prevent, modules vanishing from under a running suite.
    test "it builds nothing" do
      assert "--no-compile" in CmsHarness.TestDatabase.reset_args()
    end

    # The provisioning call site, which 6d9523a9 did not touch. Refusing here is
    # worse than refusing in the reset: the database is never brought up to
    # date, exunit runs against a schema behind the code, and the result is bulk
    # failures across contexts the session never touched. b0486568 documents 15
    # such findings, all five named files passing once the merge completed.
    test "creating and migrating skip the deps check too" do
      assert "--no-deps-check" in CmsHarness.TestDatabase.provision_args()
    end

    # Unlike the reset, this one must still compile — a migration runs against
    # the project's own code. Skipping the lock comparison is not skipping the
    # build.
    test "provisioning does not skip compilation" do
      refute "--no-compile" in CmsHarness.TestDatabase.provision_args()
    end
  end

  describe "env/1" do
    # An analyzer that refused to run because it could not manage a database
    # would be a worse failure than the one this exists to fix.
    test "an environment with no working directory asks for no isolation" do
      assert TestDatabase.env(%{cwd: nil}) == []
    end
  end

  describe "a tree that gains migrations while the harness runs" do
    # The setup work is memoized, and the key used to be the partition alone —
    # so a merge that brought migrations into a running harness was never
    # migrated. Twenty-five commits with four migrations landed that way and
    # every sweep afterwards reported 259 failures on a column that existed in
    # the tree and not in the database.
    #
    # That is this module's own failure mode wearing a disguise: correctly
    # isolated, still wrong, and nothing in the output saying which.
    setup do
      {:ok, root} = Briefly.create(directory: true)
      migrations = Path.join(root, "priv/repo/migrations")
      File.mkdir_p!(migrations)
      File.write!(Path.join(migrations, "20260101000000_create_things.exs"), "")

      {:ok, env} = CodeMySpec.Environments.create(:local, working_dir: root)

      %{env: env, dir: migrations}
    end

    test "a new migration file makes the harness set the database up again", %{
      env: env,
      dir: dir
    } do
      before = env |> TestDatabase.env() |> setup_key(env)

      File.write!(Path.join(dir, "20260807000000_add_billing.exs"), "")

      refute before == setup_key(TestDatabase.env(env), env),
             "a migration arriving under a running harness has to invalidate the " <>
               "cached setup, or the analyzer answers from last week's schema"
    end

    test "an unchanged migration set is not set up twice", %{env: env} do
      first = setup_key(TestDatabase.env(env), env)

      assert first == setup_key(TestDatabase.env(env), env),
             "the migrate costs ~37s and sits on every exunit sweep; it is paid " <>
               "when the migrations change and not otherwise"
    end
  end

  # The cache key is private, so it is observed the way the code does: whatever
  # `:persistent_term` holds for this partition after a call.
  defp setup_key(_result, %{cwd: cwd}) do
    partition = TestDatabase.partition_for(cwd)

    :persistent_term.get()
    |> Enum.filter(fn
      {{CmsHarness.TestDatabase, ^partition, _fingerprint}, _value} -> true
      _ -> false
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
