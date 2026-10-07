defmodule CodeMySpec.CheckTestMigrationsTest do
  @moduledoc """
  The guard that stops a stale worktree database reading as broken code.

  `f58acb37`: two rebases on one worktree produced 374 and then 166 failures,
  spread across contexts the agent had never touched, with nothing naming a
  migration. Both times `ecto.migrate` took it straight to 0. The guard exists
  so that arrives as one sentence instead.

  It had no test, and its failure mode is silence — a first version wrapped the
  migrator in `try/rescue` with a bare `_ -> :ok`, swallowed the sandbox
  ownership error, and read as a clean database. So the thing worth asserting is
  not that it passes on a current database; it is that it can still say no.

  Driven by deleting a `schema_migrations` row inside the test's own sandbox
  transaction, which rolls back. That is the real query against the real table
  rather than a stubbed count, and it is the only way to make a database that is
  genuinely behind without migrating anything.
  """

  use CodeMySpecTest.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Mix.Tasks.Cms.CheckTestMigrations

  describe "pending/0" do
    # The analyzer runs its own partition (`h<sha8>` / `h<sha8>s`), which
    # `mix ecto.migrate` never reaches, so that database can be behind while
    # this one is current (d86b09cd, `mix cms.migrate_test_partitions`). None
    # of these may depend on *which* database they landed on, or the gate's
    # own partitioned run reports a stale schema and reads as broken code â
    # the exact failure this file exists to name (f58acb37).
    #
    # So the deletion tests assert the *relative* property they check: a
    # version that was applied and then removed comes back as pending, whatever
    # else is or is not pending beside it. Comparing against an empty list
    # would test the database rather than the check.
    test "names a migration the database has not applied" do
      version = newest_applied()

      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [version])

      assert {:ok, pending} = CheckTestMigrations.pending()

      assert version in pending_versions(pending),
             "the one migration removed from schema_migrations did not come back " <>
               "as pending, so this check cannot detect the state it exists for"
    end

    test "reports every unapplied migration, not just the newest" do
      [first, second] = Enum.take(applied_descending(), 2)

      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
        [first, second]
      ])

      assert {:ok, pending} = CheckTestMigrations.pending()
      versions = pending_versions(pending)

      assert first in versions and second in versions
    end
  end

  describe "refuse_if_behind!/0" do
    # Currency is this test's subject, so it cannot be made to own a behind
    # database by deleting a row â the guard's whole job is to answer this
    # question about whatever database it is given. Asserted as the two-way
    # property instead: silent when there is nothing pending, and refusing when
    # there is. A partitioned analyzer run whose database lagged would otherwise
    # report the guard as broken when it is doing exactly what it should.
    test "is silent on a current database and refuses a behind one" do
      assert_pending_answers(CheckTestMigrations.pending())
    end

    test "raises, and the message carries what to run" do
      version = newest_applied()
      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [version])

      %{message: message} =
        assert_raise(RuntimeError, fn -> CheckTestMigrations.refuse_if_behind!() end)

      assert message =~ "1 migration(s) behind"
      assert message =~ to_string(version)

      assert message =~ "ecto.migrate",
             "an agent reading this has just seen a suite fail and needs the " <>
               "command, not a diagnosis"

      assert message =~ "MIX_ENV=test",
             "a bare `mix ecto.migrate` resolves to dev, which is the database " <>
               "every agent shares"
    end

    # The analyzer runs under `h<sha8>` / `h<sha8>s`, which the interactive
    # session never touches. Printing a bare command tells the reader to migrate
    # a database that is not the one refusing — advice that cannot work and reads
    # as though it should. One agent followed it and stayed blocked for three
    # days across 50 rejected runs (6f89b278).
    test "names the partition when one is set, so the command targets the right database" do
      version = newest_applied()
      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [version])

      System.put_env("MIX_TEST_PARTITION", "habcd1234")
      on_exit(fn -> System.delete_env("MIX_TEST_PARTITION") end)

      %{message: message} =
        assert_raise(RuntimeError, fn -> CheckTestMigrations.refuse_if_behind!() end)

      assert message =~ "MIX_TEST_PARTITION=habcd1234 MIX_ENV=test mix ecto.migrate"
    end
  end

  defp newest_applied, do: applied_descending() |> hd()

  # Straight off `schema_migrations`, newest first.
  #
  # A first version paired each one back to its filename on disk so the
  # assertions could match `pending/0`'s `{version, name}` shape. That meant
  # re-parsing migration filenames here — a `case` in a test file, which the
  # project forbids, and a second copy of the logic under test, which is worse:
  # a test that reimplements what it checks agrees with itself rather than with
  # the code.
  #
  # The name was never needed. Versions are what identify a migration, and they
  # come out of the table with nothing to parse and nothing to branch on.
  defp applied_descending do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT version FROM schema_migrations ORDER BY version DESC", [])

    Enum.map(rows, fn [version] -> version end)
  end

  defp pending_versions(pending), do: Enum.map(pending, fn {version, _name} -> version end)

  # Function heads rather than a `case`, which this project forbids in a test
  # file — including in a helper, as `a_queued_promotion_does_not_hold_the_only_
  # task_slot_test.exs` records.
  defp assert_pending_answers({:ok, []}),
    do: assert(:ok = CheckTestMigrations.refuse_if_behind!())

  defp assert_pending_answers({:ok, _pending}),
    do: assert_raise(RuntimeError, fn -> CheckTestMigrations.refuse_if_behind!() end)

  defp assert_pending_answers({:error, reason}),
    do: flunk("pending/0 could not read the schema: #{inspect(reason)}")
end
