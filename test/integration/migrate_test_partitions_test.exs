defmodule CodeMySpec.Integration.MigrateTestPartitionsTest do
  @moduledoc """
  Migrating a partition this VM did not boot with.

  `d86b09cd`: `MIX_ENV=test mix ecto.migrate` only ever reaches the
  interactive partition, so a worktree's spex and exunit siblings drift and
  nothing says so — the whole point of this task is a database other than the
  one `Repo` is already connected to.

  `migrate_if_exists/1` is the reachable half of that: it never touches the
  environment or a working copy's onboarding file, so it is exercised here
  against a real, throwaway database rather than this suite's own connection
  — the same distinction `check_test_migrations_create_test.exs` draws for its
  own storage functions, and for the same reason: this is what genuinely talks
  to Postgres outside the sandbox, not a decision worth mocking.

  Excluded by default (`:live`), same as this directory's other real-backend
  tests: three real `storage_up`/`storage_down` cycles and two full migration
  runs against actual Postgres connections is exactly the load this project's
  own 3e9b7568 says a busy box turns into `{:error, "killed"}` rather than a
  clean pass or fail — measured here directly, retried three times against a
  shared machine at load 20-30 before moving this out of the default sweep.
  """

  use ExUnit.Case, async: false

  @moduletag :live

  alias CodeMySpec.Repo
  alias Mix.Tasks.Cms.MigrateTestPartitions

  # Unique per test run so concurrent suites on this machine — this project's
  # own norm — never share one, and a leftover from a killed run cannot be
  # mistaken for a fresh one either.
  defp scratch_database, do: "code_my_spec_test_migrate_partitions_#{System.unique_integer([:positive])}"

  defp drop(database) do
    Repo.__adapter__().storage_down(Keyword.put(Repo.config(), :database, database))
  end

  # A raw Postgrex connection rather than `Repo` itself, dynamic or not —
  # this suite's own connection is to a different database entirely and is
  # sandboxed, and reusing `Repo` for a second, unsandboxed purpose in the
  # same test process is what produced `DBConnection.OwnershipError: cannot
  # find ownership process` under load. Nothing here needs Ecto; it needs to
  # ask Postgres a count.
  defp applied_migration_count(database) do
    opts = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: opts[:hostname],
        username: opts[:username],
        password: opts[:password],
        database: database
      )

    %{rows: [[count]]} = Postgrex.query!(conn, "SELECT count(*) FROM schema_migrations", [])
    GenServer.stop(conn)
    count
  end

  test "a database that does not exist is left alone" do
    database = scratch_database()

    assert MigrateTestPartitions.migrate_if_exists(database) == :absent

    assert Repo.__adapter__().storage_status(Keyword.put(Repo.config(), :database, database)) ==
             :down,
           "the whole point of :absent is that nothing was created — CheckTestMigrations " <>
             "already owns that decision"
  end

  test "a database that exists is migrated, and left connectable afterward" do
    database = scratch_database()
    config = Keyword.put(Repo.config(), :database, database)
    :ok = Repo.__adapter__().storage_up(config)
    on_exit(fn -> drop(database) end)

    assert MigrateTestPartitions.migrate_if_exists(database) == :migrated
    assert applied_migration_count(database) > 0,
           "migrated should mean every migration on disk actually ran, not just that " <>
             "the connection succeeded"
  end

  test "running it twice on an already-current database is a harmless no-op" do
    database = scratch_database()
    config = Keyword.put(Repo.config(), :database, database)
    :ok = Repo.__adapter__().storage_up(config)
    on_exit(fn -> drop(database) end)

    assert MigrateTestPartitions.migrate_if_exists(database) == :migrated
    assert MigrateTestPartitions.migrate_if_exists(database) == :migrated
  end
end
