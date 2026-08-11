defmodule CmsHarness.TestDatabase do
  @moduledoc """
  A test database per working copy, so the analyzer's answer is about the tree
  it was pointed at.

  ## The failure this exists to stop

  `mix test` uses whatever database `config/test.exs` names, and on a machine
  running several agents that is one database shared by every checkout.
  Whichever one migrated last wins and the others inherit its schema.

  Measured here, same commit, same suite: **36 failures** on the shared database
  and **1** on its own. The whole difference was one column — `conversations.type`,
  `NOT NULL`, added by a branch this checkout does not have. Every insert on this
  branch then died, and the stop hook reported ~25 failures across four test
  files as though this branch had broken them.

  That is worse than slow. The analyzer's verdict is what the harness is *for*,
  and an agent that believes it will start repairing code that was never broken.
  Nothing in the output distinguishes "your code is wrong" from "this database is
  not yours".

  ## Per working copy, not per project

  Two worktrees of one project is the ordinary case — a branch each — and they
  need different schemas at the same time, which is exactly what a project-keyed
  name would deny them. So the partition is derived from the absolute path of the
  working copy.

  ## Degrading rather than guessing

  Setting `MIX_TEST_PARTITION` only isolates a project whose `config/test.exs`
  reads it. Where it does (the Phoenix default, and this repo), the database has
  to exist, so this creates and migrates it first. Where it does not, the name is
  unchanged and this is a no-op.

  If either step fails — no Ecto, no database server, a project that does not
  work this way — no partition is set and the run proceeds exactly as it did
  before. An analyzer that refused to run because it could not manage a database
  would be a worse failure than the one this fixes.

  ## Staying migrated

  Isolation alone is not enough: a database of one's own that is a schema behind
  produces the same indistinguishable failures as a shared one. The migrate is
  therefore keyed on the set of migration files, not on the harness's lifetime,
  so a tree that gains migrations while the harness is running picks them up.
  """

  require Logger

  alias CodeMySpec.Environments

  @doc """
  Environment for a `mix test` in `env`, isolating its database when it can.

  Returns `[]` when isolation is not available, which is the signal to run
  against whatever the project already uses.

  `build_env` is the caller's `MIX_BUILD_PATH`, passed on to the `mix`
  invocations this makes. Without it they take the default path — `_build/test`,
  the tree the agent's own `mix test` writes — and `ecto.create`/`ecto.migrate`
  compile the project before running, so provisioning the analyzer's database
  compiled into the agent's tree. That is the collision `AnalyzerEnv` exists to
  prevent, described in its own moduledoc: modules vanish from under a running
  suite and return as "module X is not available" for a module that plainly
  exists.

  It is rare — `ensure_once/3` memoises per partition per migration set — but it
  fires on a fresh working copy and after a rebase that brings migrations, which
  is exactly when the agent is likely to be compiling too.
  """
  @spec env(Environments.Environment.t(), [{String.t(), String.t()}], String.t() | nil) ::
          [{String.t(), String.t()}]
  def env(environment, build_env \\ [], source \\ nil)

  def env(%{cwd: cwd} = environment, build_env, source) when is_binary(cwd) do
    partition = partition_for(cwd, source)

    case ensure_once(environment, partition, build_env) do
      :ok ->
        [{"MIX_TEST_PARTITION", partition}]

      {:error, reason} ->
        # Once per run, at info: a project that does not use Ecto would
        # otherwise log a warning on every sweep forever.
        Logger.info(
          "[CmsHarness] no isolated test database for #{cwd} (#{reason}); " <>
            "using the project's own. Failures may belong to another checkout."
        )

        []
    end
  end

  def env(_environment, _build_env, _source), do: []

  @doc """
  Empty the analyzer's tables before a suite runs.

  Isolation keeps another checkout's schema out. It does not keep *data* out,
  and the database is created once and reused forever, so a single row that
  escapes the ExUnit sandbox and commits is permanent.

  Measured here: two `users` and three `users_tokens` committed at one moment
  blocked five consecutive stops. The report was

      ** (MatchError) no match of right hand side value: {4, nil}
      code: {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt])

  from a test asserting the table holds exactly its own row. It held three
  strangers as well. The same file passed 41/0 against every other database on
  the machine, and 47/0 against this one once emptied — so the output is
  indistinguishable from a genuine break in user creation, which is the
  property this module exists to eliminate.

  Truncating rather than dropping: the schema is already correct by the time
  this runs, and reusing it keeps the expensive migrate on its existing key.

  Best effort by design, and quiet about it. A project with no Ecto, no
  Postgres, or no privilege to truncate gets the behaviour it had before,
  because a sweep that refuses to run is a worse failure than one that starts
  dirty.
  """
  @spec reset_data(Environments.Environment.t(), [{String.t(), String.t()}]) :: :ok
  def reset_data(environment, extra_env) do
    case List.keyfind(extra_env, "MIX_TEST_PARTITION", 0) do
      nil ->
        # No partition means no database of ours to empty. Truncating whatever
        # the project uses by default would be someone else's data.
        :ok

      {_, partition} ->
        do_reset(environment, partition, build_env(extra_env))
    end
  end

  # Run in the analyzer's build tree, not the agent's.
  #
  # `--no-compile` means this only ever *loads* a tree, so pointing it at the
  # default would read `_build/test` — the tree the agent's own `mix test`
  # writes. Two ways that goes wrong: it fails outright on a checkout where the
  # agent has never compiled in test env, and the failure is quiet by design,
  # so the reset silently stops happening and the residue this exists to clear
  # comes back. The path is already in `extra_env`; it just was not passed on.
  defp build_env(extra_env) do
    case List.keyfind(extra_env, "MIX_BUILD_PATH", 0) do
      nil -> []
      pair -> [pair]
    end
  end

  # `--no-deps-check` because `--no-compile` does not imply it, and the check
  # refuses on a lock mismatch — the state a rebase leaves between bringing a
  # new `mix.lock` and the next `mix deps.get`. Measured on this machine: five
  # resets refused with
  #
  #     Unchecked dependencies for environment test:
  #     * client_utils (Hex package)
  #       lock mismatch: the dependency is out of date
  #
  # four of them inside ten minutes of rebasing. Nothing is being built here —
  # `--no-compile` already says so — and the deps are present and loadable; only
  # the recorded version disagreed. So the check had nothing to protect and cost
  # the reset entirely, in the window where a rebase makes residue most likely.
  @doc false
  # Public so the flags can be asserted without shelling out, the same reason
  # `CredoRun.reproduce_command/0` is. The failure this guards against is a
  # refusal, logged at info and otherwise invisible — nothing downstream would
  # fail if a flag were dropped, which is what makes it worth pinning.
  def reset_args, do: ["run", "--no-compile", "--no-deps-check"]

  defp do_reset(environment, partition, build_env) do
    args = reset_args() ++ ["-e", truncate_script()]

    case run_mix_capturing(environment, partition, args, build_env) do
      {:ok, output} ->
        report_rows_removed(output, partition)

      {:error, reason} ->
        # Says what follows from it, because this stays at info — a project with
        # no Ecto would otherwise warn on every sweep forever — and an info line
        # nobody can act on is how a repair stops running unnoticed.
        Logger.info(
          "[CmsHarness] could not empty the analyzer database (#{reason}). This run " <>
            "starts against whatever the last one left; committed residue there " <>
            "reads as test failures in files this session never touched."
        )

        :ok
    end
  end

  # A silent repair that runs every sweep is how a defect stops being visible.
  #
  # This only ever logged failures, so a database that started clean and ended
  # dirty left no trace: three sweeps in a row read as "no rows were written"
  # and as "rows were written and quietly removed" identically, and the second
  # is the one worth knowing about. Rows here mean something escaped the ExUnit
  # sandbox and committed, which is a defect wherever it happens — not routine
  # tidying.
  #
  # Quiet in the normal case: nothing removed, nothing said.
  defp report_rows_removed(output, partition) do
    case Regex.run(~r/cms_reset_rows=(\d+)/, to_string(output)) do
      [_, "0"] ->
        :ok

      [_, count] ->
        Logger.warning(
          "[CmsHarness] removed #{count} committed row(s) from the analyzer database " <>
            "#{partition} before this run. Rows here escaped the ExUnit sandbox — the " <>
            "suite that wrote them has a process writing outside its test transaction."
        )

        :ok

      nil ->
        :ok
    end
  end

  # Repos come from the project's own `:ecto_repos` rather than a hardcoded
  # module, so this stays a harness that works on projects other than its own.
  #
  # `schema_migrations` is excluded because emptying it would silently undo the
  # migrate and hand back the schema-drift failure this module already fixed.
  defp truncate_script do
    ~S"""
    app = Mix.Project.config()[:app]

    for repo <- Application.get_env(app, :ecto_repos, []) do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          repo,
          "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'",
          []
        )

      names = Enum.map(rows, fn [t] -> ~s("#{t}") end)

      # Counted before truncating, so the log can say whether anything was
      # actually there. A sum across tables is enough to answer "did something
      # commit"; which table it was is a question for the next run's detail.
      total =
        Enum.reduce(names, 0, fn name, acc ->
          {:ok, %{rows: [[n]]}} = Ecto.Adapters.SQL.query(repo, "SELECT count(*) FROM " <> name, [])
          acc + n
        end)

      IO.puts("cms_reset_rows=" <> Integer.to_string(total))

      case names do
        [] -> :ok
        names -> Ecto.Adapters.SQL.query!(repo, "TRUNCATE " <> Enum.join(names, ", ") <> " RESTART IDENTITY CASCADE", [])
      end
    end
    """
  end

  @doc """
  The partition name for a working copy.

  Short, stable, and derived from the absolute path — two worktrees of one
  project get different databases, and the same worktree gets the same one
  across restarts so the migrate is paid once.
  """
  @spec partition_for(String.t()) :: String.t()
  def partition_for(cwd) do
    digest =
      cwd
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "h#{digest}"
  end

  @doc """
  The partition name for a working copy and one analyzer source.

  spex gets its own; everything else keeps the shared one.

  `Analysis` enqueues compiler, exunit and spex together, so exunit and spex
  suites run at the same time — and they ran against one database. Symptom
  (`bcad622d`): a sweep truncates before exunit and rows appear *during* it. 13
  committed `requirements` rows against an empty `projects` table, orphans of a
  project that no longer exists, and 17 failures in a file whose suite had
  passed 3,936/0 two minutes earlier. Failures that name files the session
  never touched and read exactly like real ones.

  Only spex moves. Giving exunit a new name would orphan the database it has
  and force a fresh `ecto.create` + `ecto.migrate`, measured at 37.6s; spex
  pays that once and nothing else pays it at all.

  The suffix rather than a separate digest so the two stay visibly related —
  `h1a2b3c4d` and `h1a2b3c4ds` are recognisably one working copy when you are
  looking at a list of databases wondering which to drop.
  """
  @spec partition_for(String.t(), String.t() | nil) :: String.t()
  def partition_for(cwd, "spex"), do: partition_for(cwd) <> "s"
  def partition_for(cwd, _source), do: partition_for(cwd)

  # Once per partition per *migration set*, because it is not cheap: measured at
  # 37.6s on this repo, and it was on the path of every exunit sweep.
  #
  # The key used to be the partition alone, on the reasoning that migrations
  # arrive when the harness restarts and the harness restarts when its code
  # changes. That is wrong whenever a running harness is pointed at a tree that
  # gains migrations — a merge, a rebase, a branch switch. It happened here:
  # twenty-five commits carrying four migrations landed under a harness that had
  # been up for hours, and every sweep afterwards ran against the old schema and
  # reported 259 failures on `column a0.stripe_customer_id does not exist`.
  #
  # Which is this module's own failure mode, one layer up. The database was
  # correctly isolated and still wrong, and nothing in the output said so.
  #
  # So the migration filenames are part of the key. Listing a directory is
  # cheap; a `mix` boot is not, and this still pays for one only when the set
  # actually changes.
  #
  # Cached on failure too. A project with no Ecto would otherwise pay two failing
  # `mix` boots before every test run, forever, to reach the same answer.
  defp ensure_once(environment, partition, build_env) do
    key = {__MODULE__, partition, migrations_fingerprint(environment)}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = ensure_database(environment, partition, build_env)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  # The sorted migration filenames, hashed. Names carry the version prefix, so
  # adding, removing or renaming one changes this; editing a file's body does
  # not, which is correct — an applied migration is not re-run.
  #
  # An unreadable directory degrades to a constant, restoring the old
  # once-per-partition behaviour rather than re-migrating on every sweep.
  defp migrations_fingerprint(environment) do
    case Environments.list_directory(environment, "priv/repo/migrations") do
      {:ok, entries} ->
        entries |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:md5, &1))

      _ ->
        :no_migrations_dir
    end
  end

  defp ensure_database(environment, partition, build_env) do
    with :ok <- run_mix(environment, partition, ["ecto.create", "--quiet"], build_env) do
      run_mix(environment, partition, ["ecto.migrate", "--quiet"], build_env)
    end
  end

  defp run_mix(environment, partition, args, extra) do
    case run_mix_capturing(environment, partition, args, extra) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Same invocation, but hands back stdout — the reset reads a row count out of
  # it, and `ecto.create`/`ecto.migrate` have nothing to say on success.
  defp run_mix_capturing(environment, partition, args, extra) do
    cmd_env =
      [
        {"MIX_ENV", "test"},
        {"MIX_TEST_PARTITION", partition}
      ] ++ extra ++ Environments.clean_otp_env()

    case Environments.cmd(environment, "mix", args, stderr_to_stdout: true, env: cmd_env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "mix #{hd(args)} exited #{status}: #{excerpt(output)}"}
    end
  rescue
    exception -> {:error, "mix #{hd(args)} crashed: #{Exception.message(exception)}"}
  end

  defp excerpt(output), do: output |> String.trim() |> String.slice(0, 160)
end
