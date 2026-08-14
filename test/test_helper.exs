# :live hits real provider APIs and creates real resources. Never in the
# normal suite — run it deliberately with `mix test --only live`.
# :sops drives the real `sops` and `age` binaries, because the claim those
# tests make is whether a keypair actually corresponds — which only the real
# tools can answer. On a machine without them there is nothing to run.
#
# Decided here rather than inside the tests. The alternative was a `setup` that
# returned `skip: true` and eight test bodies wrapped in `unless ctx[:skip]`,
# which is a test branching on state it should control: it reads as a test that
# ran and passed, and would go on reading that way if `available?/0` started
# answering false for a reason nobody intended.
sops_exclusions = if CodeMySpec.Provisioning.Sops.available?(), do: [], else: [:sops]

ExUnit.start(
  # :docker builds a real image on this machine — seconds, and it needs a
  # working daemon. Run it with `mix test --include docker` when the build
  # sequence changes.
  # :fleet needs the local fleet up (`docker/fleet/fleet.sh up`) — real boxes
  # over real SSH, on this machine. Run it with `mix test --only fleet`.
  # :analyzer rsyncs a copy of a real Phoenix project out of
  # `../code_my_spec_test_repos` and runs `mix`, `credo` and `sobelow` inside
  # it. Four files, and they are the last thing in the default suite that
  # touched that directory — which every worktree reaches through a symlink to
  # one shared copy, so two agents running suites collided there. Everything
  # else now reads the committed recordings in `test/fixtures/analyzer_output/`.
  # Run it with `just test-analyzer` (or `mix test --only analyzer`) when
  # changing an analyzer, and after `mix cms.test_fixtures`.
  exclude:
    [
      :scenario,
      :e2e,
      :pending,
      :live,
      :docker,
      :fleet,
      :registry,
      :analyzer,
      :record_google_login_shape,
      :record_github_login_shape
    ] ++ sops_exclusions
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
#
# The check itself now lives in `Mix.Tasks.Cms.CheckTestMigrations`, because
# `mix spex` needed it too and had no way to get it: it loads no helper at all,
# so the one command an agent is told to run for BDD work was the one that
# skipped this — and the symptom arrived as `ERROR 42703 (undefined_column)`
# from inside a `given_` step, naming no migration (40b6424d). The `spex` alias
# runs that task before booting; this line is the same check for `mix test`.
Mix.Tasks.Cms.CheckTestMigrations.refuse_if_behind!()

# The dirty-database check that stood here is gone, along with the escape it
# watched for.
#
# It reported rows left in users/accounts/projects/stories/components at suite
# start, on the reasoning that a row which escaped the sandbox and committed is
# permanent and surfaces later as unrelated tests failing on unscoped reads.
# That was true, and worth reporting while nobody knew what was writing them.
#
# Two things closed it. `CmsHarness.TestDatabase` no longer truncates anything —
# it computes a database name and stops — after its truncate was found running
# against dev, which it emptied three times on 2026-08-13. And the env guard
# below stops a fixture working copy joining the live server, which was writing
# a harness row per temp root.
#
# Measured after both: a full suite of 4368 tests leaves all five tables at zero.
# A check that reports a condition which no longer occurs is a thing to read and
# dismiss on every run, and this one was 65 of this file's 248 lines.

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

# Fixture repositories are NOT refreshed here. `ensure_fixture_fresh/0` ran
# `git pull` in both of them on every `mix test` — and they live under
# `../code_my_spec_test_repos`, which every worktree reaches through a symlink
# to one shared directory. Two agents starting suites near each other were two
# pulls racing in one repository before a single test ran.
#
# The recorded analyzer output those repos used to generate is now committed
# under `test/fixtures/analyzer_output/` — 60KB of JSON, read by the tests that
# want it. Regenerate deliberately with `mix cms.test_fixtures`.
#
# The pool below creates copies lazily, so a checkout without the fixture
# repository costs nothing until one of the five analyzer tests asks for one.

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
