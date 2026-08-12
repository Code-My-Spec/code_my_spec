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
  invocation costs ~14s, and it is pure waste for the analyzer, whose partition
  `CmsHarness.TestDatabase` already keeps current by keying its migrate on the
  migration filename set. This is one query, and it only ever speaks when
  something is actually wrong.
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
        IO.puts(
          :stderr,
          "[check_test_migrations] could not check for pending migrations " <>
            "(#{inspect(reason)}); proceeding. If the suite fails in bulk across " <>
            "untouched contexts, try `MIX_ENV=test mix ecto.migrate` first."
        )

        :ok
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
    This working copy's test database is #{length(pending)} migration(s) behind.

    Pending: #{names}#{more}

    Run `MIX_ENV=test mix ecto.migrate` and try again.

    Refusing rather than running: the suite would fail in bulk, across contexts
    you have not touched, with nothing naming a migration — which reads as
    broken code and costs a bisect of the wrong thing.
    """
  end

  defp trailing_count(remaining) when remaining > 0, do: ", and #{remaining} more"
  defp trailing_count(_remaining), do: ""
end
