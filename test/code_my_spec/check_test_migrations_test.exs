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
    test "is empty when the database has applied every migration on disk" do
      assert {:ok, []} = CheckTestMigrations.pending(),
             "this worktree's test database is behind, which is the condition " <>
               "under test elsewhere in this file — run " <>
               "`MIX_ENV=test mix ecto.migrate` and re-run"
    end

    test "names a migration the database has not applied" do
      {version, name} = newest_applied()

      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [version])

      assert {:ok, pending} = CheckTestMigrations.pending()

      assert {version, name} in pending,
             "the one migration removed from schema_migrations did not come back " <>
               "as pending, so this check cannot detect the state it exists for"
    end

    test "reports every unapplied migration, not just the newest" do
      [{first, _}, {second, _}] = Enum.take(applied_descending(), 2)

      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
        [first, second]
      ])

      assert {:ok, pending} = CheckTestMigrations.pending()
      versions = Enum.map(pending, fn {version, _name} -> version end)

      assert first in versions and second in versions
    end
  end

  describe "refuse_if_behind!/0" do
    test "passes silently on a current database" do
      assert :ok = CheckTestMigrations.refuse_if_behind!()
    end

    test "raises, and the message carries what to run" do
      {version, _name} = newest_applied()
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
      {version, _name} = newest_applied()
      SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [version])

      System.put_env("MIX_TEST_PARTITION", "habcd1234")
      on_exit(fn -> System.delete_env("MIX_TEST_PARTITION") end)

      %{message: message} =
        assert_raise(RuntimeError, fn -> CheckTestMigrations.refuse_if_behind!() end)

      assert message =~ "MIX_TEST_PARTITION=habcd1234 MIX_ENV=test mix ecto.migrate"
    end
  end

  defp newest_applied, do: applied_descending() |> hd()

  # Paired back to the filename on disk, because `pending/0` returns
  # `{version, name}` and the name comes from the file rather than the table.
  defp applied_descending do
    %{rows: rows} = SQL.query!(Repo, "SELECT version FROM schema_migrations", [])
    applied = MapSet.new(rows, fn [version] -> version end)

    "priv/repo/migrations"
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.flat_map(fn file ->
      case Integer.parse(file) do
        {version, "_" <> rest} -> [{version, Path.rootname(rest)}]
        _ -> []
      end
    end)
    |> Enum.filter(fn {version, _} -> MapSet.member?(applied, version) end)
    |> Enum.sort(:desc)
  end
end
