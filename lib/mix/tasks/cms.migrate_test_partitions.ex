defmodule Mix.Tasks.Cms.MigrateTestPartitions do
  @shortdoc "Migrate every test database this working copy uses"

  @moduledoc """
  Migrate every partition of this working copy's test database.

      MIX_ENV=test mix cms.migrate_test_partitions

  A working copy has three, not one:

      code_my_spec_test<partition>     the interactive session's `mix test`
      code_my_spec_test<partition>a    the analyzer's exunit run
      code_my_spec_test<partition>s    the analyzer's spex run

  A running VM is connected to exactly one — whichever the environment resolved
  — so `MIX_ENV=test mix ecto.migrate` migrates that one and says nothing about
  the other two. After a schema change a targeted `mix test` passes against the
  base while the analyzer reports hundreds of failures against a partition on
  last week's schema, and `ecto.migrate` answers "Migrations already up",
  truthfully, about a different database.

  Measured (`d86b09cd`): 479 spex problems, every one
  `ERROR 42703 (undefined_column) column q0.resolution does not exist`, against
  a tree whose migration was written, committed and applied. An hour across two
  people, and four confident wrong diagnoses on the way — that the migration had
  not been written, that it had not been committed, that the analyzer was
  serving stale records, that the fingerprint had deadlocked. The actual answer
  was two databases with different schemas both answering, and nothing naming
  which one had.

  ## "Up to date" is about versions, not about DDL

  This reports a database current when `schema_migrations` holds every version
  on disk. That is Ecto's model and there is no other one available — but it can
  be true of a database whose tables are wrong, and this repo has produced
  exactly that.

  Two migrations were stamped `20260912010000`. Only one row can record that
  version, so on some databases the loser was marked applied without ever
  running. Renumbering fixed the file and could not un-record the version, so
  those databases carry a complete `schema_migrations` and an incomplete schema,
  and nothing that reads versions can tell.

  Measured 2026-09-12: after this task reported all three partitions up to date,
  `working_copies_device_id_fkey` was `ON DELETE CASCADE` on the base and
  `ON DELETE RESTRICT` on the spex partition. Criterion 2848 asserts a device
  deletion takes its checkouts with it; it passed on one database and raised
  `Ecto.ConstraintError` on the other, from the same commit.

  **The repair for that is `DROP DATABASE`, not another migrate.** These hold
  nothing but test data and are rebuilt on demand, so dropping the `a` and `s`
  partitions and letting them be created and migrated from an empty history is
  cheap and is the only thing that guarantees the schema matches the migrations.
  Reach for it when a suite fails on one partition and passes on another.

  ## Existing partitions only — nothing is created here

  A partition nothing has used yet has no database, and that is not a problem to
  solve here: `Mix.Tasks.Cms.CheckTestMigrations` creates one lazily at the
  moment something actually needs it. Creating them here as well would be a
  second place holding that judgement, and it would pay a full migration
  (~37.6s) for a database that may never be used — on a box whose Postgres
  connection arithmetic already reaches its limit exactly (`51fb4adb`).

  ## Why a task and not an alias on `ecto.migrate`

  `cms.check_test_migrations` refuses a run whose database is behind and prints
  the exact command for *that* partition, because migrating on every invocation
  costs ~14s and a suite should not pay it. That refusal is the signal; this is
  the remedy it points at. Three databases means three of those refusals, one
  run at a time — this settles all three in one pass.

  ## Why this runs entirely in this VM

  Each sibling is migrated through its own dynamically-configured connection to
  `Repo`, never by exporting `MIX_TEST_PARTITION` and shelling out to `mix` per
  partition. That is the reason `CmsHarness.TestDatabase`'s own moduledoc gives
  for not doing it: `Environments.clean_otp_env/0` scrubs `MIX_ENV` from a
  child's environment, so a shelled-out "migrate this partition" ran against
  **dev** and a sibling truncate emptied the shared development database three
  times on 2026-08-13. A dynamic repo connection is named by this function call,
  in this process, from a database string built here — there is no child and no
  environment variable for anything to misdirect.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias ClientUtils.Harness.Onboarding
  alias CodeMySpec.Repo

  @requirements ["app.start"]

  @suffixes ["", "a", "s"]

  @impl Mix.Task
  def run(_args) do
    base = "code_my_spec_test" <> Onboarding.resolve_partition!(File.cwd!())

    case partitions(base) do
      {:ok, databases} -> Enum.each(databases, &report(&1, migrate_if_exists(&1)))
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc """
  The three databases belonging to `base`.

  The base comes from `Onboarding.resolve_partition!/1` — what onboarding
  recorded for this working copy — and not from the resolved repo config or from
  `MIX_TEST_PARTITION`.

  Both of those are wrong here for the same reason. A session inherits
  `MIX_TEST_PARTITION` from whatever launched it, and on this machine that is
  routinely another checkout's value (measured: a session in this worktree
  carrying `h0a2edd36`, the main checkout's, while its own recording says
  `h789652af`). And the resolved database may already carry an analyzer suffix,
  which cannot be taken back off reliably — a partition is a path digest and can
  itself end in `a` or `s`, so stripping produces a base nothing uses and a run
  that migrates three databases which do not exist.

  Reading the recording has neither problem: it is one value, it names this
  working copy, and it is the same one `config/test.exs` prefers. A copy with no
  recording raises, naming the command that fixes it.
  """
  @spec partitions(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def partitions(base) do
    cond do
      Mix.env() != :test ->
        {:error, "refusing to migrate test databases from MIX_ENV=#{Mix.env()}; use MIX_ENV=test"}

      not String.starts_with?(base, "code_my_spec_test") ->
        {:error, "refusing to migrate #{base}, which is not one of this repo's test databases"}

      true ->
        {:ok, Enum.map(@suffixes, &(base <> &1))}
    end
  end

  @doc """
  Migrate `database` if it exists, doing nothing (and creating nothing) if it
  does not. `:migrated`, `:absent`, or `{:error, reason}` when the existence
  check itself could not answer — never a raise, so one sibling this cannot read
  does not stop the others from being checked.

  Public, and taking a bare database name rather than a partition or a cwd, so
  the migration mechanism is reachable without a real working copy's onboarding
  file to resolve one.
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
  # expects a test process to check a connection out before using it and nothing
  # here is one.
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

  # Said per database, including the ones nothing happened to. "Which database
  # answered" is the fact this whole family of failures turns on, and a task
  # that printed only what it changed would leave the reader to infer the rest.
  defp report(database, :migrated), do: Mix.shell().info("  migrated  #{database}")

  defp report(database, :absent),
    do: Mix.shell().info("  absent    #{database} (created on first use)")

  defp report(database, {:error, reason}),
    do: Mix.shell().error("  failed    #{database}: #{inspect(reason)}")
end
