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
