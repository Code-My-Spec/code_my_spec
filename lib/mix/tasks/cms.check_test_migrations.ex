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

  ## A database that is *missing* is made, not reported

  Behind and absent are different questions and get different answers. Behind
  raises — migrating on every run is the ~14s nobody should pay. Absent is the
  ordinary state of a partition nothing has used yet, and it is created and
  migrated here, in this VM, before the suite starts.

  That is not a return to what `TestDatabase` lost on 2026-08-13. What it lost
  shelled out to `mix` with an environment that had `MIX_ENV` scrubbed out of it,
  so "create the test database" acted on **dev** and a sibling truncate emptied
  the shared development database three times. The hazard was a background
  process holding DDL rights over a server an absent environment variable could
  re-aim. There is no child process here and no environment to give one:
  `storage_up/1` and `Ecto.Migrator` act on `CodeMySpec.Repo.config()`, which in
  `MIX_ENV=test` is this partition's database by construction. `creatable/1`
  refuses anything else.

  ## Naming the right database is still load-bearing

  The analyzer runs under a partition the interactive session never touches —
  `h<sha8>a` for exunit, `h<sha8>s` for spex — so "run `MIX_ENV=test mix
  ecto.migrate`" migrates the wrong database and changes nothing. One agent
  followed that advice, migrated its own partition, and stayed blocked for three
  days across 50 rejected runs (6f89b278). Everything printed below names the
  partition it is about, for that reason.
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
        unanswerable(reason)
    end
  end

  # A database that does not exist is made, not reported.
  #
  # It used to print two commands and proceed, and the comment below still says
  # why that was the ordinary first run rather than an anomaly. Printing them was
  # the wrong half of a correct instinct: the reason `TestDatabase` stopped
  # creating databases is that it shelled out to `mix` with an environment that
  # had `MIX_ENV` scrubbed, so "create the test database" acted on **dev** and a
  # sibling truncate emptied it three times on 2026-08-13. The hazard was the
  # child process and its environment, not the act of creating.
  #
  # Nothing is shelled out here. `storage_up/1` and `Ecto.Migrator` run in this
  # VM, against `CodeMySpec.Repo.config()` — which in `MIX_ENV=test` is this
  # partition's database by construction, and cannot be pointed at dev by an
  # environment variable a parent forgot to set, because there is no child to
  # give an environment to. That closes the class rather than avoiding it.
  #
  # Any other reason still prints and proceeds. "Cannot answer" is not "cannot
  # exist", and a check that responded to an ownership error by creating a
  # database would be the silent-swallow shape this file has fought twice.
  defp unanswerable(reason) do
    if missing_database?(reason), do: provision(), else: report(reason)
  end

  defp report(reason) do
    IO.puts(:stderr, cannot_answer_message(reason))
    :ok
  end

  @doc """
  Whether `reason` is Postgres saying the database is not there.

  `3D000 invalid_catalog_name`, which arrives either as the error itself or
  wrapped in a connection error depending on whether the pool had already given
  up on connecting — so both shapes are matched, and by the code rather than by
  the sentence, which is localised.

  Public because it is the discrimination that decides whether anything is
  created at all. "Cannot answer" is not "cannot exist", and a check that
  responded to an ownership error by creating a database would be the
  silent-swallow shape this file has fought twice.
  """
  @spec missing_database?(term()) :: boolean()
  def missing_database?(%Postgrex.Error{postgres: %{code: :invalid_catalog_name}}), do: true
  def missing_database?(%DBConnection.ConnectionError{message: message}), do: missing?(message)
  def missing_database?(reason) when is_binary(reason), do: missing?(reason)
  def missing_database?(_), do: false

  defp missing?(message) when is_binary(message) do
    String.contains?(message, "3D000") or String.contains?(message, "does not exist")
  end

  defp missing?(_), do: false

  defp provision do
    config = CodeMySpec.Repo.config()

    with :ok <- creatable(config),
         :ok <- create(config) do
      migrate()
    else
      {:error, message} ->
        IO.puts(:stderr, "[check_test_migrations] #{message}")
        :ok
    end
  end

  @doc """
  Whether this VM may create the database `config` names.

  The guard the 2026-08-13 incident needed and did not have: a run that cannot
  name its own database acts on none. `MIX_ENV=test` is already guaranteed by
  every caller — `mix test`'s helper and the `spex` alias — so this can only
  fire if something calls it from somewhere new, which is exactly the case worth
  refusing rather than trusting.

  Public so it can be exercised directly. Reached only through `provision/0`, it
  would be testable solely by arranging a missing database from a VM that is not
  in the test environment, which is a thing the test suite cannot be.
  """
  @spec creatable(keyword()) :: :ok | {:error, String.t()}
  def creatable(config) do
    cond do
      Mix.env() != :test ->
        {:error,
         "refusing to create a database from MIX_ENV=#{Mix.env()}; only :test creates one"}

      blank?(config[:database]) ->
        {:error, "refusing to create a database this repo cannot name"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp create(config) do
    IO.puts(:stderr, "[check_test_migrations] creating #{config[:database]}")

    case config[:adapter].storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> {:error, "could not create #{config[:database]}: #{inspect(reason)}"}
    end
  end

  # `with_repo/2` rather than `Ecto.Migrator.run/3` straight: the pool started
  # against a database that did not exist and its connections are in backoff, so
  # the migrator needs a repo it knows is up. It is a no-op for the already
  # started case, which is every case here.
  defp migrate do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(CodeMySpec.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end

  # What is left when "could not check" does not mean "is not there".
  #
  # It used to end "If it does not exist: <create>, then <migrate>", which was
  # the right advice while a missing database was this branch's ordinary case.
  # It no longer reaches here — `missing_database?/1` sends it to `provision/0` —
  # so the remaining reasons are ones no `ecto.create` answers: an ownership
  # error under a manual sandbox, a server that refused the connection, a
  # credential. Repeating the create advice there would be a confident
  # instruction about a different defect, which is the costliest kind of wrong
  # message and one this file has already paid for once (6f89b278).
  defp cannot_answer_message(reason) do
    """
    [check_test_migrations] could not check #{database_label()} (#{inspect(reason)}); proceeding.
    Not a missing database — that would have been created. Something else stopped the query.\
    """
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
