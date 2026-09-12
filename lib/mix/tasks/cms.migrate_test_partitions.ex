defmodule Mix.Tasks.Cms.MigrateTestPartitions do
  @shortdoc "Migrate every test-database partition this working copy has, not just the one this VM booted with"

  @moduledoc """
  Migrate every partition of this working copy's test database.

      MIX_ENV=test mix cms.migrate_test_partitions

  A worktree's test database is not one database. `CmsHarness.TestDatabase`
  gives it three: the interactive session's own (what `mix test` and a plain
  `MIX_ENV=test mix ecto.migrate` reach), the analyzer's spex partition
  (`<partition>s`), and the analyzer's exunit partition (`<partition>a`). A
  running VM is connected to exactly one of these — whichever
  `MIX_TEST_PARTITION` it booted with — so `ecto.migrate` migrates that one
  and nothing tells you the other two exist, let alone that they are now
  behind.

  Measured (d86b09cd): a migration landed on the interactive partition,
  `ecto.migrate` reported "already up" against it, and the analyzer's spex
  sweep reported 479 `undefined_column` failures against the sibling
  partition nobody had touched — a correct migration, a correct-looking
  `ecto.migrate`, and a database nothing in that command's own output
  mentioned. This closes the gap at the source: run this once after a
  migration lands in a worktree and every partition that exists is current,
  rather than relying on the next spex or exunit run to discover the drift
  by failing in bulk.

  Only partitions that already exist are migrated. A partition nothing has
  used yet is not created here — `Mix.Tasks.Cms.CheckTestMigrations` already
  creates one lazily the moment something actually needs it, and this task
  deciding to create one too would be a second place with that judgement call.

  ## Why this runs entirely in this VM

  Each sibling is migrated through its own dynamically-configured connection
  to `Repo` (`Ecto.Repo.put_dynamic_repo/1`) — never by exporting
  `MIX_TEST_PARTITION` and shelling out to `mix` for each one. That is the same
  reason `CmsHarness.TestDatabase`'s own moduledoc gives for not doing that:
  `Environments.clean_otp_env/0` scrubs `MIX_ENV` from a child's environment,
  so a shelled-out "migrate this partition" ran against **dev** three times on
  2026-08-13. A dynamic repo connection is named by this function call, in
  this process, from a database string built here — there is no child and no
  environment variable for anything to misdirect.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CmsHarness.TestDatabase
  alias CodeMySpec.Repo

  @requirements ["app.start"]

  # `nil` first: the interactive partition is what a plain `ecto.migrate`
  # already reaches, and leading with it makes the output read as "the one you
  # know about, then the two you don't" rather than an arbitrary order.
  @sources [nil, "spex", "exunit"]

  @impl Mix.Task
  def run(_args) do
    cwd = File.cwd!()

    Enum.each(@sources, fn source ->
      database = database_name(cwd, source)
      report(migrate_if_exists(database), label(source), database)
    end)

    :ok
  end

  defp label(nil), do: "interactive"
  defp label(source), do: source

  defp report(:migrated, label, database),
    do: Mix.shell().info("[migrate_test_partitions] #{label}: migrated #{database}")

  defp report(:absent, label, database),
    do:
      Mix.shell().info(
        "[migrate_test_partitions] #{label}: #{database} does not exist yet, skipping"
      )

  defp report({:error, reason}, label, database),
    do:
      Mix.shell().error(
        "[migrate_test_partitions] #{label}: could not check #{database} (#{inspect(reason)})"
      )

  defp database_name(cwd, source) do
    partition = TestDatabase.partition_for(cwd, source)
    booted_partition = TestDatabase.partition_for(cwd)
    prefix = String.replace_suffix(to_string(Repo.config()[:database]), booted_partition, "")
    prefix <> partition
  end

  @doc """
  Migrate `database` if it exists, doing nothing (and creating nothing) if it
  does not. `:migrated`, `:absent`, or `{:error, reason}` when the existence
  check itself could not answer — never a raise, so one sibling this cannot
  read does not stop the others from being checked.

  Public, and taking a bare database name rather than a partition or a cwd, so
  the actual migration mechanism — connect, migrate, disconnect, touching
  nothing else `Repo` is already doing — is reachable without needing a real
  working copy's onboarding file to resolve one.
  """
  @spec migrate_if_exists(String.t()) :: :migrated | :absent | {:error, term()}
  def migrate_if_exists(database) do
    config = Keyword.put(Repo.config(), :database, database)

    case Repo.__adapter__().storage_status(config) do
      :up -> migrate(config)
      :down -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  # A plain, unpooled connection for the duration of one migration — never the
  # sandbox pool `config/test.exs` configures for everyday test runs, which
  # expects a test process to check a connection out before using it and
  # nothing here is one.
  defp migrate(config) do
    config =
      config
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    {:ok, pid} = Repo.start_link(config)
    previous = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(pid)
      Ecto.Migrator.run(Repo, :up, all: true)
      :migrated
    after
      Repo.put_dynamic_repo(previous)
      GenServer.stop(pid)
    end
  end
end
