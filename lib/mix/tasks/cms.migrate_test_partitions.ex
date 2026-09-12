defmodule Mix.Tasks.Cms.MigrateTestPartitions do
  @shortdoc "Migrate every test database this working copy uses"

  @moduledoc """
  Migrate all three of this working copy's test databases, not just the one
  `mix ecto.migrate` happens to be pointed at.

  A working copy has three:

      code_my_spec_test<partition>     the interactive session's `mix test`
      code_my_spec_test<partition>a    the analyzer's exunit run
      code_my_spec_test<partition>s    the analyzer's spex run

  `MIX_ENV=test mix ecto.migrate` migrates whichever one the environment
  resolves to and says nothing about the other two. So after a schema change a
  targeted `mix test` passes against the base while the analyzer reports
  hundreds of failures against a partition still on last week's schema, and
  `ecto.migrate` answers "Migrations already up" — truthfully, about a different
  database.

  Measured (`d86b09cd`): 479 spex problems, every one
  `ERROR 42703 (undefined_column) column q0.resolution does not exist`, against
  a tree whose migration was written, committed and applied. An hour across two
  people, and four confident wrong diagnoses on the way — that the migration had
  not been written, that it had not been committed, that the analyzer was
  serving stale records, that the fingerprint had deadlocked. The actual answer
  was two databases with different schemas both answering, and nothing naming
  which one had.

  ## Why a task and not an alias on `ecto.migrate`

  `cms.check_test_migrations` refuses a run whose database is behind and prints
  the exact command for *that* partition, because migrating on every invocation
  costs ~14s and a suite should not pay it. That refusal is the signal; this is
  the remedy it points at. Three databases means three of those refusals, one
  run at a time — this settles all three in one pass.

  ## In this VM, like the check

  `Ecto.Migrator.with_repo/2` per database, no child process. The version this
  replaces in `TestDatabase` shelled out to `mix` with an environment that had
  `MIX_ENV` scrubbed from it, so "migrate the test database" acted on **dev**
  and a sibling truncate emptied the shared development database three times on
  2026-08-13. There is no child here to hand a wrong environment to, and
  `partitions/2` refuses to name a database that is not a `code_my_spec_test…`.

  `app.config` rather than `app.start`: the repo must not already be running
  under one database when the point is to visit three. `with_repo/2` starts each
  and stops what it started.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias ClientUtils.Harness.Onboarding

  @requirements ["app.config"]

  @suffixes ["", "a", "s"]

  @impl Mix.Task
  def run(_args) do
    config = CodeMySpec.Repo.config()
    base = "code_my_spec_test" <> Onboarding.resolve_partition!(File.cwd!())

    case partitions(base) do
      {:ok, databases} -> Enum.each(databases, &migrate(config, &1))
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

  defp migrate(config, database) do
    Application.put_env(
      :code_my_spec,
      CodeMySpec.Repo,
      Keyword.put(config, :database, database)
    )

    create(config, database)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(CodeMySpec.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    Mix.shell().info("[migrate_test_partitions] #{database} up to date")
  end

  # A partition nothing has used yet has no database. Creating it here is the
  # same call `cms.check_test_migrations` makes for the same reason, and
  # `:already_up` is the ordinary answer.
  # `Repo.__adapter__/0` rather than `config[:adapter]`: under `app.config` the
  # repo has not started, and an unstarted repo's config carries no adapter key —
  # which fails as `nil.storage_up/1`, a message that names nothing useful.
  defp create(config, database) do
    case CodeMySpec.Repo.__adapter__().storage_up(Keyword.put(config, :database, database)) do
      :ok -> Mix.shell().info("[migrate_test_partitions] created #{database}")
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise("could not create #{database}: #{inspect(reason)}")
    end
  end
end
