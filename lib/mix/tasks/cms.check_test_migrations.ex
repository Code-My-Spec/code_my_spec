defmodule Mix.Tasks.Cms.CheckTestMigrations do
  @shortdoc "Refuse to run against a test database this working copy has outgrown"

  @moduledoc """
  Answer whether this working copy's test database is behind its migrations.

      MIX_ENV=test mix cms.check_test_migrations

  `config/test.exs` gives every worktree its own database
  (`code_my_spec_test_<worktree>`), deliberately, so agents cannot re-schema each
  other. The consequence is that each database migrates only when someone runs
  migrations *in that worktree*, while `git pull` moves the code in all of them.
  So every rebase that carries a migration leaves a worktree behind, and the
  failure wears the costume of broken code.

  Measured twice on one worktree immediately after `git rebase origin/main`: 374
  failures, then 166, spread across contexts the agent had never touched, with
  nothing naming a migration. Both times `MIX_ENV=test mix ecto.migrate` took it
  straight to 0. (f58acb37) An agent that has just rebased and sees 374 failures
  has no reason to suspect migrations; the rational move is to bisect its own
  changes, which is exactly wrong and expensive.

  `mix test` has had this check since `f58acb37`, inline in `test_helper.exs`.
  `mix spex` never did — it loads no helper at all, so the one command an agent
  is told to run for BDD work was the one that skipped it, and the symptom
  arrived as `(Postgrex.Error) ERROR 42703 (undefined_column)` from inside a
  `given_` step with a full Ecto stacktrace and nothing naming a migration.

  Living here rather than in `test/test_helper.exs` so both callers share one
  copy: the helper calls `refuse_if_behind!/0`, and the `spex` alias runs this
  task before booting. That is deliberately cheaper than teaching the `../spex`
  fork to load a helper — it changes how every spex run boots, in a fork shared
  by two repos, and the ordering against its `ExUnit.start/1` wants care.

  A refusal rather than an alias that migrates: measured, migrating on every
  invocation costs ~14s, and this is one query that only ever speaks when
  something is actually wrong.

  ## The analyzer's partition is nobody's job, and that is deliberate

  This used to add "pure waste for the analyzer, whose partition
  `CmsHarness.TestDatabase` already keeps current by keying its migrate on the
  migration filename set". That stopped being true on 2026-08-13, when
  `TestDatabase` lost its create and migrate: both shelled out to `mix` with an
  environment that had `MIX_ENV` scrubbed out of it, so they ran against **dev**,
  and a sibling truncate emptied the shared development database three times.
  Nothing in this project migrates a database from code any more.

  So the analyzer's partitions — `h<sha8>` for exunit, `h<sha8>s` for spex — are
  now migrated by a human or not at all, and the refusal below is the only thing
  that says so. That makes naming the *right* database load-bearing rather than
  cosmetic: the analyzer runs under a partition the interactive session never
  touches, so "run `MIX_ENV=test mix ecto.migrate`" migrates the wrong database
  and changes nothing. One agent followed that advice, migrated its own
  partition, and stayed blocked for three days across 50 rejected runs (6f89b278).
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias Ecto.Adapters.SQL

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    refuse_if_behind!()
  end

  @doc """
  Raise if the test database is behind, print if the question cannot be answered.

  Cannot-answer is reported, never treated as clean. A first version of this
  wrapped `Ecto.Migrator` in `try/rescue` with a bare `_ -> :ok`, which
  swallowed the sandbox ownership error, answered nothing, and read as a clean
  database. A check that fails silently is worse than no check.

  Callers must invoke this **before** `Sandbox.mode(:manual)`: under manual mode
  a process that has not checked out ownership cannot query at all.
  """
  @spec refuse_if_behind!() :: :ok
  def refuse_if_behind! do
    case pending() do
      {:ok, []} ->
        :ok

      {:ok, pending} ->
        raise behind_message(pending)

      {:error, reason} ->
        IO.puts(:stderr, cannot_answer_message(reason))

        :ok
    end
  end

  # Names the database and the partition-correct commands. Since `TestDatabase`
  # stopped creating databases, "does not exist" is the ordinary first run for an
  # analyzer partition rather than an anomaly — and it arrives here, because a
  # missing database cannot answer what it has applied.
  defp cannot_answer_message(reason) do
    """
    [check_test_migrations] could not check #{database_label()} (#{inspect(reason)}); proceeding.
    If it does not exist: #{create_command()}, then #{migrate_command()}\
    """
  end

  defp create_command do
    case partition() do
      nil -> "MIX_ENV=test mix ecto.create"
      partition -> "MIX_TEST_PARTITION=#{partition} MIX_ENV=test mix ecto.create"
    end
  end

  @doc """
  Migrations on disk that the test database has not applied, newest last.

  Built from two functions that return tuples — `File.ls/1` and
  `Ecto.Adapters.SQL.query/3` — rather than `Ecto.Migrator.migrations/1`, which
  raises.
  """
  @spec pending() :: {:ok, [{integer(), String.t()}]} | {:error, term()}
  def pending do
    with {:ok, files} <- File.ls(Path.join(["priv", "repo", "migrations"])),
         {:ok, %{rows: rows}} <- applied_versions() do
      applied = MapSet.new(rows, fn [version] -> version end)

      {:ok,
       files
       |> migration_versions()
       |> Enum.reject(fn {version, _name} -> MapSet.member?(applied, version) end)
       |> Enum.sort()}
    end
  end

  defp applied_versions do
    SQL.query(CodeMySpec.Repo, "SELECT version FROM schema_migrations", [])
  end

  defp migration_versions(files) do
    files
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.flat_map(fn file ->
      case Integer.parse(file) do
        {version, "_" <> rest} -> [{version, Path.rootname(rest)}]
        _ -> []
      end
    end)
  end

  defp behind_message(pending) do
    names = pending |> Enum.take(3) |> Enum.map_join(", ", fn {v, n} -> "#{v}_#{n}" end)
    more = trailing_count(length(pending) - 3)

    """
    #{database_label()} is #{length(pending)} migration(s) behind.

    Pending: #{names}#{more}

    Run `#{migrate_command()}` and try again.

    Refusing rather than running: the suite would fail in bulk, across contexts
    you have not touched, with nothing naming a migration — which reads as
    broken code and costs a bisect of the wrong thing.
    """
  end

  # Name the database, not "your test database". The analyzer runs under its own
  # partition, so the database this checked is very often not the one the reader
  # would think to migrate.
  defp database_label do
    case database_name() do
      nil -> "This working copy's test database"
      name -> "The test database `#{name}`"
    end
  end

  # The command for *this* partition. A bare `MIX_ENV=test mix ecto.migrate`
  # resolves to the interactive per-worktree database from `config/test.exs`, so
  # printing it to an analyzer run tells the reader to migrate a database that is
  # not the one refusing — advice that cannot work and reads as if it should.
  defp migrate_command do
    case partition() do
      nil -> "MIX_ENV=test mix ecto.migrate"
      partition -> "MIX_TEST_PARTITION=#{partition} MIX_ENV=test mix ecto.migrate"
    end
  end

  defp partition do
    case System.get_env("MIX_TEST_PARTITION") do
      nil -> nil
      "" -> nil
      partition -> partition
    end
  end

  defp database_name do
    CodeMySpec.Repo.config()[:database]
  rescue
    _ -> nil
  end

  defp trailing_count(remaining) when remaining > 0, do: ", and #{remaining} more"
  defp trailing_count(_remaining), do: ""
end
