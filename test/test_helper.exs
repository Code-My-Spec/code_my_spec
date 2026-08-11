# :live hits real provider APIs and creates real resources. Never in the
# normal suite — run it deliberately with `mix test --only live`.
ExUnit.start(
  # :docker builds a real image on this machine — seconds, and it needs a
  # working daemon. Run it with `mix test --include docker` when the build
  # sequence changes.
  exclude: [
    :scenario,
    :e2e,
    :pending,
    :live,
    :docker,
    :registry,
    :record_google_login_shape,
    :record_github_login_shape
  ]
)

# Refuse to run against a schema this working copy has outgrown.
#
# Nothing advances a worktree's test database, so every rebase that brings a
# migration leaves it behind — and the failure wears the costume of broken code.
# Measured twice on one worktree immediately after `git rebase origin/main`: 374
# failures, then 166, spread across contexts the agent had never touched, with
# nothing naming a migration. Both times `MIX_ENV=test mix ecto.migrate` took it
# straight to 0. (f58acb37)
#
# An agent that has just rebased and sees 374 failures has no reason to suspect
# migrations; the rational move is to bisect its own changes, which is exactly
# wrong and expensive.
#
# A refusal rather than a `test` alias that migrates: measured, the alias costs
# ~14s on *every* `mix test` invocation, and it is pure waste for the analyzer,
# whose partition `CmsHarness.TestDatabase` already keeps current by keying its
# migrate on the migration filename set. This is one query, and it only ever
# speaks when something is actually wrong.
#
# Before `Sandbox.mode(:manual)`, which is load-bearing: under manual mode a
# process that has not checked out ownership cannot query at all.
#
# Built from two functions that return tuples — `File.ls/1` and
# `Ecto.Adapters.SQL.query/3` — rather than `Ecto.Migrator.migrations/1`, which
# raises. There is no rescue here on purpose: a first version wrapped the
# migrator in `try/rescue` with a bare `_ -> :ok`, which swallowed the ownership
# error, answered nothing, and read as a clean database. A check that fails
# silently is worse than no check, and this file is full of comments about
# exactly that shape.
#
# Cannot-answer is reported, not treated as clean.
migration_versions = fn files ->
  files
  |> Enum.filter(&String.ends_with?(&1, ".exs"))
  |> Enum.flat_map(fn file ->
    case Integer.parse(file) do
      {version, "_" <> rest} -> [{version, Path.rootname(rest)}]
      _ -> []
    end
  end)
end

pending_migrations =
  case File.ls(Path.join(["priv", "repo", "migrations"])) do
    {:ok, files} ->
      case Ecto.Adapters.SQL.query(CodeMySpec.Repo, "SELECT version FROM schema_migrations", []) do
        {:ok, %{rows: rows}} ->
          applied = MapSet.new(rows, fn [version] -> version end)

          {:ok,
           files
           |> migration_versions.()
           |> Enum.reject(fn {version, _name} -> MapSet.member?(applied, version) end)
           |> Enum.sort()}

        {:error, reason} ->
          {:error, reason}
      end

    {:error, reason} ->
      {:error, reason}
  end

case pending_migrations do
  {:ok, []} ->
    :ok

  {:ok, pending} ->
    names = pending |> Enum.take(3) |> Enum.map_join(", ", fn {v, n} -> "#{v}_#{n}" end)
    more = if length(pending) > 3, do: ", and #{length(pending) - 3} more", else: ""

    raise """
    This working copy's test database is #{length(pending)} migration(s) behind.

    Pending: #{names}#{more}

    Run `MIX_ENV=test mix ecto.migrate` and try again.

    Refusing rather than running: the suite would fail in bulk, across contexts
    you have not touched, with nothing naming a migration — which reads as
    broken code and costs a bisect of the wrong thing.
    """

  {:error, reason} ->
    IO.puts(
      :stderr,
      "[test_helper] could not check for pending migrations (#{inspect(reason)}); " <>
        "proceeding. If the suite fails in bulk across untouched contexts, try " <>
        "`MIX_ENV=test mix ecto.migrate` first."
    )
end

# Say when the database starts dirty.
#
# The sandbox rolls each test back, so these tables are empty at the start of a
# run — unless something escaped it and committed, and then the row is permanent,
# because the test database is created once and reused forever.
#
# What that looks like is not a database error. It is a handful of unrelated
# tests going red: anything reading an unscoped query answers about the stranger
# instead of the row it just made. Four did here — `Repo.all(query) |> hd()` in
# the accounts repositories — and they read as broken preloads. Those four now
# scope to their own row, but the next unscoped read will not.
#
# `CmsHarness.TestDatabase.reset_data/2` truncates the *analyzer's* partition
# before every sweep for exactly this reason, and reports the count it removed
# because "a silent repair that runs every sweep is how a defect stops being
# visible". Nothing owns the database an agent's own `mix test` uses, so this
# reports rather than repairs: truncating a developer's database from a test
# helper is a bigger liberty than the problem warrants.
dirty_counts =
  case Ecto.Adapters.SQL.query(
         CodeMySpec.Repo,
         """
         SELECT 'users', count(*) FROM users
         UNION ALL SELECT 'accounts', count(*) FROM accounts
         UNION ALL SELECT 'projects', count(*) FROM projects
         UNION ALL SELECT 'stories', count(*) FROM stories
         UNION ALL SELECT 'components', count(*) FROM components
         """,
         []
       ) do
    {:ok, %{rows: rows}} -> Enum.filter(rows, fn [_table, count] -> count > 0 end)
    {:error, _reason} -> []
  end

if dirty_counts != [] do
  summary = Enum.map_join(dirty_counts, ", ", fn [table, count] -> "#{table}=#{count}" end)

  IO.puts(
    :stderr,
    "[test_helper] the test database is not empty before this run (#{summary}). " <>
      "Rows that escaped the ExUnit sandbox and committed are permanent, and they " <>
      "surface as unrelated tests failing on unscoped reads. Clear with " <>
      "`MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && " <>
      "MIX_ENV=test mix ecto.migrate`."
  )
end

Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, :manual)

# The light harness tree. Its tests drive real processes — a watcher on a real
# directory, a Slipstream client against a real websocket — rather than
# constructing them, so they need the tree `cms harness` boots.
#
# No test reaches the real CodeMySpec server, whatever the shell exports.
#
# `CmsHarness.Config` reads these straight from the environment, and the
# analyzer runs `mix test` as a child of a harness that has all of them. A test
# that started a fixture working copy therefore opened a real socket, joined,
# and `Harnesses.issue/3` wrote a row per fixture root: 81 of 86 harness rows on
# the dev server had roots under /var/folders, directories that stopped existing
# when the test ended. `Harnesses.viewing/1` defaults to the most recently
# active harness, so an operator's view then described a checkout nobody had.
#
# `FakeServer.start/1` already clears these for the tests that use it — this is
# the same guard for the ones that do not, which are exactly the ones that had
# no business connecting anywhere. Cleared before the supervisor starts, so
# nothing can read them on the way up.
#
# It is also the best candidate anyone has for the phantom failures in issue
# c8264c1f: two tests that exercise the stop hook and the analysis pipeline
# failed under the analyzer's own suite run and passed standalone. That issue
# guessed "shared application state" without a mechanism. This is one — the
# suite was joining the live server, so tests asserting how a session resolves
# were asserting against a system with real sessions in it.
#
# UPDATE: it recurred, so the guess was wrong. `stop_controller_test.exs:52`
# failed under an analyzer run on 2026-08-09 at 20:1x, with this guard in place
# and demonstrably working — the newest temp-root harness row predates the guard
# by ninety seconds, so nothing has joined the live server since. It still
# passes standalone (8 tests, 0 failures).
#
# So the live-server join was real and worth fixing, and it was not the cause.
# c8264c1f is still open and now has four eliminations rather than three:
# `_build` (isolated), the test database (isolated *and* at the same migration
# version as the agent's), the env leak (this), and "an analyzer is live" on its
# own (the named tests pass under the analyzer's exact environment).
#
# The candidate nobody has tested is the dullest one: ExUnit randomises order by
# seed, and a suite that passes at one seed and fails at another needs no
# analyzer-specific mechanism at all. That would explain every observation here
# — passes standalone, passes a full run by hand, fails the analyzer's run —
# without anything the analyzer does being special.
Enum.each(~w(CMS_SERVER_URL CMS_TOKEN CMS_DEPLOY_KEY CMS_HARNESS_ID), &System.delete_env/1)

# Started here rather than from `CodeMySpecWeb.Application`'s test children, so
# the cloud application does not gain a compile-time reference to `CmsHarness`
# that only the test suite ever wanted. Its endpoint is `server: false` in test,
# so this costs a registry and an idle DynamicSupervisor.
{:ok, _} = CmsHarness.Supervisor.start_link([])

# Auto-load envs/test.env (gitignored) for e2e tests so OAuth client_id /
# secret / test-account creds are available without manual sourcing.
# Existing process env wins (you can override per-run).
if File.exists?("envs/test.env") do
  Dotenvy.source(["envs/test.env"], side_effect: false)
  |> case do
    {:ok, vars} ->
      Enum.each(vars, fn {k, v} ->
        if System.get_env(k) in [nil, ""], do: System.put_env(k, v)
      end)

    _ ->
      :ok
  end
end

case System.get_env("LOG_LEVEL") do
  nil -> :warning
  level -> Logger.configure(level: String.to_existing_atom(level))
end

# Define mock for environments in tests
Mox.defmock(CodeMySpec.MockEnvironment, for: CodeMySpec.Environments.EnvironmentsBehaviour)

# Define mock for Git operations in tests
Mox.defmock(CodeMySpec.MockGit, for: CodeMySpec.Git.Behaviour)

# Initialize test fixture repositories
CodeMySpec.Support.TestAdapter.ensure_fixture_fresh()

# Start the test repo pool for fast directory reuse
{:ok, _} = CodeMySpec.Support.TestAdapter.Pool.start_link()

# Use TestAdapter as default Git implementation for tests
Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Support.TestAdapter)

# Use RecordingEnvironment as default for local environment in tests
Application.put_env(:code_my_spec, :environment, CodeMySpec.Support.RecordingEnvironment)

# Own the embedding TestBackend ETS table from a long-lived agent so it
# survives across async tests. Without a stable owner the table dies with
# whichever test process happened to create it, breaking the next concurrent
# test that touches the embeddings pipeline.
{:ok, owner} =
  Agent.start_link(
    fn ->
      :ets.new(
        :code_my_spec_embeddings_test_backend,
        [:set, :public, :named_table, read_concurrency: true]
      )
    end,
    name: CodeMySpec.Embeddings.TestBackend.TableOwner
  )

# Don't let GC reap the owner — pin it for the full test run.
Process.put(:test_backend_owner, owner)
