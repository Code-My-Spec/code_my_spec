defmodule CodeMySpec.TestMigrations do
  @moduledoc """
  Whether this working copy's test database is behind its migrations.

  Extracted from `Mix.Tasks.Cms.CheckTestMigrations`, which is now a thin
  wrapper over `refuse_if_behind!/0`: a `Mix.Tasks.*` module is only callable
  from outside its own boundary when `classify_to:`'d into one AND named
  under that boundary's own namespace for `exports: :all` to actually cover
  it (confirmed against Boundary's own source -- a `classify_to:` override
  does not do this on its own). Living here instead, under `CodeMySpec.*`,
  needs no such override: a spex driving story 1013's criterion 917 in
  process (`CodeMySpecSpex.Fixtures`) can call `refuse_if_behind!/0` and
  `creatable/1` directly.

  `config/test.exs` gives every worktree its own database, deliberately, so
  agents cannot re-schema each other. Each database migrates only when
  migrations run *in that worktree*, while pulling moves the code in all of
  them — and a behind database fails as hundreds of unrelated test failures
  naming no migration.

  `test/test_helper.exs` calls `refuse_if_behind!/0`, and the `spex` alias runs
  `mix cms.check_test_migrations` before booting (the spex runner loads no
  helper), so both share one copy. Both aliases also run `ecto.migrate` first;
  this is the check that names the partition when the database is still
  behind.

  ## A database that is *missing* is made, not reported

  Behind raises. Absent is the ordinary state of a partition nothing has used
  yet, and it is created and migrated here, in this VM, before the suite
  starts. Nothing is shelled out: `storage_up/1` and `Ecto.Migrator` act on
  `CodeMySpec.Repo.config()`, which in `MIX_ENV=test` is this partition's
  database by construction, and `creatable/1` refuses anything else.

  ## Naming the right database is load-bearing

  The analyzer runs under its own partitions — `h<sha8>a` for exunit,
  `h<sha8>s` for spex — so a bare `MIX_ENV=test mix ecto.migrate` migrates the
  wrong database. Everything printed below names the partition it is about.
  """

  @doc """
  Raise if the test database is behind, print if the question cannot be answered.

  Cannot-answer is reported, never treated as clean.

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

  # A database that does not exist is made, not reported — in this VM, with no
  # child process whose environment could re-aim it at dev. Any other reason
  # prints and proceeds: "cannot answer" is not "cannot exist".
  # See knowledge/platform, "Test databases".
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

  ## A missing database never actually reaches the message-text clause

  When the database genuinely does not exist, every connection in the pool
  fails to connect (the same `invalid_catalog_name`, repeatedly, on each
  backoff retry) and none ever reaches `:connected` -- so the query this
  module issues to check for pending migrations is never handed a
  connection at all. What `DBConnection` reports to the caller in that case
  is not the underlying Postgrex error; it is always a generic
  `:queue_timeout`, whose message talks about the pool being unable to
  keep up, naming neither "3D000" nor "does not exist". Confirmed directly
  by running this task against a database that does not exist: the logs
  show repeated `FATAL 3D000 (invalid_catalog_name)` connection failures,
  and the error this function actually receives is `:queue_timeout`. The
  message-text clause below was therefore dead for the one case its own
  moduledoc says this file exists for -- "a database that is missing is
  made, not reported" -- which instead silently fell through to
  `report/1` and left the suite to fail in bulk downstream, the exact
  failure mode this file exists to prevent (story 1013, criterion 917).

  Treating every `:queue_timeout` as "missing" is safe even when the real
  cause is something else (contention from other suites sharing this
  machine, say): `create/1` already treats `{:error, :already_up}` as
  `:ok`, and `Ecto.Adapters.Postgres.storage_up/1` opens its own
  connection to the `postgres` maintenance database rather than going
  through this pool, so it is unaffected by whatever stalled the original
  query and answers "already up" immediately for a database that exists.
  Attempting it when it was not actually needed costs one extra,
  idempotent round trip; not attempting it when it was needed costs the
  whole suite.

  Public because it is the discrimination that decides whether anything is
  created at all: an ownership error must never lead to creating a database.
  """
  @spec missing_database?(term()) :: boolean()
  def missing_database?(%Postgrex.Error{postgres: %{code: :invalid_catalog_name}}), do: true
  def missing_database?(%DBConnection.ConnectionError{reason: :queue_timeout}), do: true
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

  A run that cannot name its own database acts on none. Every caller already
  guarantees `MIX_ENV=test`, so this fires only for a new caller — exactly the
  case worth refusing.

  Public so it can be exercised directly (story 1013, criterion 918): through
  `provision/0` it would need a missing database from a VM outside the test
  environment.
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

  # `Repo.__adapter__()`, not `config[:adapter]`: `Repo.config/0` carries no
  # adapter key, so that read `nil`.
  defp create(config) do
    IO.puts(:stderr, "[check_test_migrations] creating #{config[:database]}")

    case CodeMySpec.Repo.__adapter__().storage_up(config) do
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

  # What is left when "could not check" does not mean "is not there": an
  # ownership error under a manual sandbox, a refused connection, a credential.
  # No `ecto.create` advice here — it would be confident advice about a
  # different defect.
  defp cannot_answer_message(reason) do
    """
    [check_test_migrations] could not check #{database_label()} (#{inspect(reason)}); proceeding.
    Not a missing database — that would have been created. Something else stopped the query.\
    """
  end

  @doc """
  Migrations on disk that the test database has not applied, newest last.

  Built from two functions that return tuples — `File.ls/1` and
  `CodeMySpec.Repo.query/2`, rather than `Ecto.Migrator.migrations/1`, which
  raises. `Repo.query/2`, not `Ecto.Adapters.SQL.query(CodeMySpec.Repo, ...)`:
  the latter resolves a bare module atom via `GenServer.whereis/1`, which
  always finds the one real, globally-named connection and never consults
  `get_dynamic_repo/0` — so a spec driving this against a throwaway
  connection in-process (story 1013, criterion 917) needs the module's own
  `query/2`, which does.
  """
  @spec pending() :: {:ok, [{integer(), String.t()}]} | {:error, term()}
  def pending do
    # The repo's own set: `priv/sqlite` when it is SQLite.
    with {:ok, files} <- File.ls(Ecto.Migrator.migrations_path(CodeMySpec.Repo)),
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
    CodeMySpec.Repo.query("SELECT version FROM schema_migrations", [])
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
