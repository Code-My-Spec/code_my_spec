defmodule CmsHarness.TestDatabaseTest do
  @moduledoc """
  Which database the analyzer's `mix test` runs against.

  The property under test is isolation between checkouts. Two worktrees of one
  project is the ordinary case — a branch each — and they need different schemas
  at the same time. Sharing one database means whichever migrated last decides
  what the others' tests see, and the analyzer reports the difference as failures
  belonging to whoever asked.

  These assert properties of **assignment**, which is `Onboarding.partition_name/1`
  — the function onboarding uses once to pick a name. `TestDatabase.partition_for/1`
  no longer derives anything: it reads what was recorded and refuses a copy that
  has none, which is covered by `CmsHarness.TestDatabasePartitionTest`.

  Splitting them is the point. Deriving on every resolve is what let the analyzer
  ignore the recorded value and compute its own (acaf8035).

  This module now only *names* the partition. It used to create and migrate the
  database as well, and that shelled out to `mix ecto.create` / `ecto.migrate`
  with an environment that had `MIX_ENV` scrubbed out of it — so the migration
  landed in `code_my_spec_dev` instead. Nothing in this project migrates a
  database from code any more; a missing one fails the run by name and a human
  answers it.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.TestDatabase

  describe "partition_for/1" do
    test "two checkouts of one project get different databases" do
      main = Onboarding.partition_name("/src/app")
      worktree = Onboarding.partition_name("/src/app/.claude/worktrees/feature")

      refute main == worktree,
             "a worktree needs its own schema; sharing is how one branch's " <>
               "migration becomes another branch's test failures"
    end

    test "the same checkout gets the same database across restarts" do
      assert Onboarding.partition_name("/src/app") == Onboarding.partition_name("/src/app")
    end

    test "spellings of one path agree, so a harness does not migrate twice" do
      assert Onboarding.partition_name("/src/app") == Onboarding.partition_name("/src/app/")

      assert Onboarding.partition_name("/src/app") ==
               Onboarding.partition_name("/src/other/../app")
    end

    test "it is a usable database suffix" do
      assert Onboarding.partition_name("/src/app") =~ ~r/^h[0-9a-f]{8}$/,
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
end
