import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# CMS_E2E turns this env into a real, listening server against a real pool.
#
# It exists to answer a question no in-process test can: does a separate OS
# process, speaking the actual wire protocol, get what it expects? The light
# harness is exactly that, and the four defects found in `HarnessProjectChannel`
# were all invisible to `Phoenix.ChannelTest` — a hand-built socket carrying
# assigns production never sets, and a reply asserted as a term rather than
# encoded. Those are not gaps in the tests so much as gaps in what that kind of
# test *can* see.
#
# Why the test env rather than dev: `MIX_ENV=test` does not contend for the
# compile lock the running dev servers hold, so this cannot 500 :4000/:4003/:4004
# the way building against dev would. Its own database, so a run cannot disturb
# the ordinary suite.
e2e? = System.get_env("CMS_E2E") in ~w(1 true)

# `mix cms.eval` runs outside ExUnit and cannot use the sandbox pool.
eval? = System.get_env("CMS_EVAL") in ~w(1 true)

# One database per checkout, so two agents cannot re-schema each other.
#
# Worktrees share this machine's Postgres. An agent running `mix test` in one
# migrates the database every other checkout is using — and from whatever
# branch it is on, pushed or not. That happened: three migrations from an
# unpushed branch added `files.harness_id NOT NULL`, and a checkout without
# that migration failed 138 tests on a column its code had never heard of.
#
# It is expensive to diagnose because it never says so. The first symptom was
# `CodeMySpecWeb.Application.start/2 is undefined`, which reads as a broken
# build; then NOT NULL violations; then `ON CONFLICT` errors as the schema
# shifted under successive runs. The same commit passed 3541/3541 against a
# private database.
#
# `MIX_TEST_PARTITION` already existed for exactly this shape and was simply
# never set per worktree. An explicit value still wins — CI sets it per
# partition — and the main checkout keeps the bare name so nothing has to be
# recreated for it.
# In a linked worktree `.git` is a file pointing at the real git dir rather
# than a directory. That is the whole test, and it is the same one
# `cms_new` generates into every project — this repo carried a weaker copy
# that matched on the path containing "worktrees", so a worktree created
# anywhere but `.claude/worktrees/` silently shared the primary database and
# got exactly the failure the comment above describes.
#
# The primary checkout keeps the bare name, and an explicit
# MIX_TEST_PARTITION still wins.
# The working copy's own recorded value first, and the environment after it.
#
# That order is the whole point of the variable. It exists so each worktree gets
# its own schema, and it was resolved environment-first — so a session whose
# shell inherited another worktree's value ran every `mix test` against that
# worktree's database. Two sessions, one schema, each migrating past the other:
# `mix ecto.migrate` answers "already up" truthfully while `\d stories` disagrees
# with what `schema_migrations` says was applied. Issue 63265687, where the
# reporter and the other session turned out to be the same pair of worktrees.
#
# Same inversion as `CMS_PROJECT_ID` (a08f3d09) and `CMS_HARNESS_ID` (1db9c15c),
# for the same reason: a working copy knows what it is, and the environment
# belongs to whatever launched the shell.
#
# The recorded value is the one onboarding wrote and the one the harness reads
# through `TestDatabase.partition_for/1`, so preferring it also stops config and
# harness disagreeing — the cwd fallback below answers `_phx-new-generator`
# where the recording says `h789652af`, which is a third database again.
#
# Read with a regex rather than a JSON decoder: this file is evaluated before
# the application is compiled, and a config that cannot be read must degrade to
# the fallback rather than fail to load.
recorded_partition =
  with {:ok, contents} <- File.read(Path.join(File.cwd!(), ".claude/settings.local.json")),
       [_, value] <- Regex.run(~r/"MIX_TEST_PARTITION"\s*:\s*"([^"]+)"/, contents) do
    value
  else
    _ -> nil
  end

requested_partition = System.get_env("MIX_TEST_PARTITION")

# The analyzer's own sub-partition is the one environment value that must win.
#
# `TestDatabase.partition_for/2` gives each concurrently-running suite its own
# database by appending a letter to this copy's recorded partition — `…a` for
# exunit, `…s` for spex — and the only channel it has to say so is
# `MIX_TEST_PARTITION`. Recorded-first demoted that channel below the recorded
# value, so the suffix was computed, exported, and then ignored: the analyzer's
# exunit, its spex, and the agent's interactive `mix test` all resolved to the
# base database again. Measured 2026-09-12 — `MIX_TEST_PARTITION=h789652afs`
# resolved to `code_my_spec_testh789652af`, and the `…a`/`…s` databases sat
# untouched since 2026-09-07 while the comment above claimed the environment
# still won.
#
# That is `bcad622d` restored in full: two suites, one database, a sweep
# truncating under the other, and failures that name files the session never
# touched.
#
# Narrow on purpose. What is accepted is not "an environment value" but "the
# recorded value plus one suffix" — a name that can only describe *this* working
# copy. A value inherited from another worktree cannot match, so the inversion
# that this restores nothing of (issue 63265687, two sessions migrating past each
# other) stays closed. Anything else the environment says still loses.
#
# `_<n>` is a spex shard of any of these (`mix cms.spex`).
own_sub_partition? =
  is_binary(recorded_partition) and is_binary(requested_partition) and
    Regex.match?(~r/^#{Regex.escape(recorded_partition)}[as]?(_\d+)?$/, requested_partition) and
    requested_partition != recorded_partition

# In a linked worktree `.git` is a file pointing at the real git dir rather than
# a directory. The primary checkout keeps the bare name.
partition =
  cond do
    own_sub_partition? ->
      requested_partition

    recorded_partition ->
      recorded_partition

    requested_partition ->
      requested_partition

    File.regular?(Path.join(File.cwd!(), ".git")) ->
      "_" <> Path.basename(File.cwd!())

    true ->
      ""
  end

# The manual provisioning drill, against the database the *deployed* app talks
# back to.
#
# Everything the drill provisions is real, and the steps that prove themselves
# by something arriving back at CodeMySpec — the widget's socket message, the
# inbound mail probe — cannot close against a sandbox: the deployed application
# authenticates over the tunnel at dev.codemyspec.com, which serves the dev
# database, and a rolled-back test database has never heard of the project it
# presents. Dev answers 403 and the mail routes nowhere, and both look like
# broken features rather than two databases.
#
# So the drill uses dev's, with a real pool for the same reason `e2e?` does:
# a sandboxed connection is invisible to anything out of process, and the whole
# point here is that something out of process can see it.
#
# `CMS_DRILL_DB` and not the default, because this writes rows that are not
# rolled back — projects, mailboxes, conversations — into a database somebody
# else is using.
drill_db? = System.get_env("CMS_DRILL_DB") in ~w(1 true dev)

test_database =
  cond do
    drill_db? -> "code_my_spec_dev"
    e2e? -> "code_my_spec_e2e"
    true -> "code_my_spec_test#{partition}"
  end

config :code_my_spec, CodeMySpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: test_database,
  # The sandbox owns connections per test process and hands nothing to an
  # external client, so an out-of-process harness cannot see anything a
  # sandboxed pool writes.
  # A real pool for anything that is not a test process.
  #
  # The sandbox hands connections to the process that owns them, so a caller
  # outside ExUnit gets "connection not available and request was dropped from
  # queue" for every checkout. `mix cms.eval` is exactly that caller: it stands
  # up a project, syncs, recomputes and then drives an agent whose every MCP
  # call needs a connection, with no test process anywhere.
  #
  # Found from the inside. An agent under criterion 3540 called
  # `get_next_requirement`, got the pool error, called it once more, and then
  # stopped and said so: "this is an infrastructure/environment issue, not
  # something retrying the same call will fix — repeated attempts would just add
  # to the queue pressure". It was right, and the criterion scored it a failure.
  pool:
    if(e2e? or drill_db? or eval?,
      do: DBConnection.ConnectionPool,
      else: Ecto.Adapters.SQL.Sandbox
    ),
  pool_size: System.schedulers_online() * 2,
  # A spex shares one sandbox connection with its own background tasks, and
  # under gate load DBConnection's 50ms target dropped waiters at ~150ms
  # (d1f5a541). A real deadlock still fails, five seconds later.
  queue_target: 5_000,
  queue_interval: 10_000

# Homebrew's Unix socket avoids TCP port exhaustion during busy local runs.
if :os.type() == {:unix, :darwin} and File.exists?("/tmp/.s.PGSQL.5432") do
  config :code_my_spec, CodeMySpec.Repo, socket_dir: "/tmp"
end

# server: false — Phoenix.ConnTest and LiveViewTest do not go through HTTP,
# so nothing here needs a listener. It was true only for Wallaby, which is no
# longer a dependency and whose test/e2e directory no longer exists.
#
# Binding the port had a real cost: every `mix test` and `mix run` grabbed
# 4002, so a concurrent background analysis run (the stop hook enqueues a full
# `mix spex`) failed the other with :eaddrinuse.
#
# Under CMS_E2E it listens on 4102 — deliberately not 4002, so an e2e server and
# an ordinary `mix test` cannot collide on the port.
# Loopback unless CMS_E2E_BIND_ALL says otherwise. A container cannot reach the
# host's loopback, so a drill needs this open — but it is opt-in and stated,
# because the alternative is an e2e server quietly listening on the LAN for
# anyone who ever sets CMS_E2E. It still carries only the throwaway e2e
# database.
e2e_ip =
  if e2e? and System.get_env("CMS_E2E_BIND_ALL") in ~w(1 true),
    do: {0, 0, 0, 0},
    else: {127, 0, 0, 1}

config :code_my_spec, CodeMySpecWeb.Endpoint,
  http: [ip: e2e_ip, port: if(e2e?, do: 4102, else: 4002)],
  secret_key_base: "uQsFkBLrXNG5yxrQkMHNLOAi5NcrEzpZut3YYEOlAFiuhpoynMd+/rJBgz6FSWsg",
  # Listens under CMS_E2E, except while seeding.
  #
  # `server: e2e?` alone meant *any* `mix run` in this env tried to bind 4102 —
  # so `e2e_seed.exs` could not run while the server it seeds for was up, which
  # is exactly when you want to run it, and it died with :eaddrinuse.
  #
  # Setting `server: false` and relying on `mix phx.server` to set
  # `:serve_endpoints` does not work here — checked, the endpoint never bound.
  # So the exception is explicit rather than inferred from a framework
  # behaviour I got wrong once already.
  server: e2e? and System.get_env("CMS_E2E_SEED") != "1"

# Light harness endpoint. A port of its own so a test run cannot talk to — or be
# talked to by — a `cms harness` someone left running on 4005.
config :code_my_spec, CmsHarness.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4105],
  server: false

# The real values are 10s and 2s; the behaviours under test are the same at a
# tenth of that, and the suite would otherwise spend most of its time waiting
# for timers it already knows the shape of.
#
# `remote_await_timeout` is 61 minutes in production — long enough to outlast
# a run queued for a machine-wide slot and then the harness's own analyzer
# kill timeout on top. At that length a test that dispatches a run and ends
# leaves the waiting task alive for most of an hour, and the
# harness-never-answered path cannot be asserted at all.
config :code_my_spec,
  harness_decision_timeout: 1_000,
  harness_watch_debounce_ms: 200,
  remote_await_timeout: 500,
  # The floor every `GenServer.call(pid, msg, timeout + call_grace_ms())`
  # site (CodeMySpec.Analysis.harness_fs_request/4,
  # CodeMySpec.Agents.Transport.Harness.call/4, CmsHarness.Token)
  # adds on top of a caller's own timeout,
  # so "still working" isn't mistaken for "gone". 5s in every real
  # environment; 1ms here so a test proving the timeout path fires pays
  # only the timeout it actually asked for, not the real grace period too.
  call_grace_ms: 1

# A port nothing serves, so a harness started without a fake server in front of
# it fails locally instead of dialling whatever is running on :4000.
#
# `CmsHarness.Config.server_url/0` falls through to a compile-time default of
# `http://localhost:4000` when nothing names a server, and test named nothing.
# So a test that starts a project subtree outside `FakeServer`'s window opens a
# real websocket to the dev server on this machine.
#
# Proven rather than supposed. `web.log` carries `[UserSocket] connect refused —
# token not found key=len<N>:<sha256 prefix>`, and every distinct key observed
# hashes to a literal in this suite:
#
#     len10:c29d9689a7ee  "stub-token"       device_test.exs
#     len14:a3ff3ea2f77e  "this-copys-key"   credentials_test.exs
#     len10:4c5dc9b77089  "test-token"       FakeServer's own
#     len12:b058b0225f91  "a-deploy-key"     mcp_controller_test.exs
#     len15:2d238f2acc96  "from-app-config"  credentials_test.exs
#
# Refused is the lucky case: those tokens are fixtures, so the join failed. A
# test holding a *real* key would have joined the running server's channel — and
# `CMS_DEPLOY_KEY` is exported in this project's own environment.
#
# Why an earlier attempt at this looked like it did nothing: it was applied in
# one worktree, and the connections come from whichever of the fifteen checkouts
# on this box is running tests. Pinning one of them moves nothing measurable.
# It has to be committed to move at all (`d96809d4`).
#
# `FakeServer.start/1` sets this to its own port and restores it, so a test that
# wants a server still gets one — this is only the fallback, which is the leak.
config :code_my_spec, :harness_server_url, "http://127.0.0.1:1"

# A terminal agent reads Claude Code's own agent list (`claude agents --json`);
# a test says what is on it instead of running `claude` (stories 1123, 1124).
config :code_my_spec, :claude_sessions, {CmsHarnessTest.ClaudeSessions, :list, []}
config :code_my_spec, :claude_config_dir, Path.expand("../tmp/test-claude-config", __DIR__)

# A harness announcing its machine reaches `CodeMySpecWeb.Endpoint` in-process
# rather than over the network — the real router, plug pipeline, controller and
# sandbox, with only the socket removed.
#
# Pinned here rather than per-test because the default is a real `Req.post` to
# `Config.server_url()`, and the harness holds a real credential. Written
# unpinned, the boot-announce spec POSTed to https://dev.codemyspec.com with a
# valid bearer token attached. That is not something each new test should have
# to remember.
# CMS_TEST_REAL_DEVICE_CLIENT (story 1013, criterion 916): a real subprocess
# driven as its own OS process has no started endpoint for the in-process
# stub to dispatch against at all -- it needs the real HTTP client, safely,
# because its own Config.server_url() points at a spec's own local listener,
# not the production server the comment above guards against. Does nothing
# unless set.
config :code_my_spec,
       :device_client,
       if(System.get_env("CMS_TEST_REAL_DEVICE_CLIENT"),
         do: CmsHarness.Device.Client.Http,
         else: CodeMySpecTest.InProcessDeviceClient
       )

# The run-wide harness tree's reporter does not tick by itself (e258f257). Its
# announce drives the endpoint in its own process, and a tick landing while a
# test held a credential queried the sandbox with no owner, crash-looped on its
# immediate restart report, and took `CmsHarness.Supervisor` — linked to the
# test runner — and the whole suite down with no summary. Tests that want a
# report drive it (`WorkingCopyReporter.report/1`) or start their own.
config :code_my_spec, :working_copy_reporter, first_report: :never, heartbeat: :never

# Authorization tests start their own process with isolated credentials and HTTP stubs.
config :code_my_spec, CmsHarness.Authorization, enabled: false
config :code_my_spec, :app_log_trimmer, interval: :never

# `CmsHarness.Projects.Generator`'s own subprocess calls, pinned for the same
# reason: the default shells out through several `mix` tasks that take real
# minutes and need a correctly-versioned `mix cms.new` archive installed on
# whatever machine runs the suite. Scripted per test via
# `CodeMySpecTest.ScriptedGeneratorRunner.script/1` instead.
config :code_my_spec, :generator_runner, CodeMySpecTest.ScriptedGeneratorRunner

# The machine an agent's process is on, without a socket in between.
#
# Pinned here because the default reaches `HarnessRegistry` for a channel to a
# real device, which no test has — so every stop and every reap would answer
# `:harness_not_connected` and nothing about process lifecycle would ever be
# exercised. Criterion 2828 has shipped as a bug three times on this project,
# each time under tests that never involved a process.
#
# A group id naming nothing answers `:ok`, so a test carrying an invented
# `os_pid` needs no process arranged for it, and one that spawns something real
# gets it genuinely signalled.
# Each test routes its own project through `CodeMySpecTest.AgentTransportRouter`;
# an unrouted project gets `InProcessAgentTransport`.
config :code_my_spec, :agent_transport, CodeMySpecTest.AgentTransportRouter

# The agent's own MCP session, without a socket. `CodeMySpecWeb.Endpoint` runs
# `server: false` here, so the harness cannot make the HTTP hop its tools make
# in production — and everything worth testing sits on either side of it. Same
# seam as `:harness_transport` for the channel.
config :code_my_spec, :harness_mcp_transport, CodeMySpecTest.InVmMcpTransport

# A served copy's socket headers, per root. A test serving a real harness
# against a listening cloud endpoint puts its SQL sandbox metadata here, and
# `CodeMySpecWeb.UserSocket` allows that test's connection from it — so the
# channel is isolated per test rather than shared across the run.
config :code_my_spec, :harness_connect_headers, CmsHarnessTest.ConnectHeaders

# Belt and braces. The seam above means the HTTP client never runs in test, but
# pinning its plug as well keeps that true even if something unsets the seam —
# and an unset plug plus a real credential is a live request that logs nothing
# when it works. CMS_TEST_REAL_DEVICE_CLIENT (story 1013, criterion 916) is the
# one case that wants exactly that: a real subprocess's own real request to a
# spec's own local listener, not the production server this pin guards against.
unless System.get_env("CMS_TEST_REAL_DEVICE_CLIENT") do
  config :code_my_spec, CmsHarness.Device.Client.Http,
    plug: {Req.Test, CmsHarness.Device.Client.Http}
end

config :code_my_spec, CmsHarness.Mcp.Http, plug: {Req.Test, CmsHarness.Mcp.Http}

# The CLI providers' answer to the pin above. A project that connected OpenAI
# launches its agents on `codex exec`, and a spex that talked to one ran it for
# real on every analysis. Replayed from a recording; an unrecorded call raises.
# Not under `mix cms.eval`: an eval measures the real model, and replaying a
# recording there measured the recording ("ready", every run).
unless eval? do
  config :code_my_spec, CmsHarness.Agents.Provider,
    command_runner: {CmsHarnessTest.RecordedCli, :run}
end

# Provisioning's pollers back off between reads — waiting for a server to boot,
# a bucket to appear, a firewall to release. Against stubs and cassettes there
# is nothing to wait for, so the sleeps are pure wall-clock: `apex_repoint_test`
# alone spent 28 of its 29 seconds asleep.
#
# The spex case already set this per-run (`:real` while recording, `:none` on
# replay); plain ExUnit tests never got it. Leaving them to sleep also made the
# suite sensitive to retry budgets — lengthening the firewall retry from 10s to
# 30s pushed an async test into a fixture collision it had merely been lucky to
# avoid.
config :code_my_spec, :provisioning_waits, :none

# In test we don't send emails
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test, unless asked for more.
#
# `LOG_LEVEL=info mix spex …` is the difference between watching a drill and
# guessing at it: the provisioning steps log what they are about to do at
# `:info`, and with those dropped a failing drill's only account of itself is
# whatever the step happened to put in its error message. Several cloud cycles
# went into a defect whose explanation was being written to a logger nobody
# could hear.
config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "warning"))

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :code_my_spec,
  env: :test,
  sql_sandbox: true,
  github_client_id: "test_github_client_id",
  github_client_secret: "test_github_client_secret",
  git_impl_module: CodeMySpec.Support.TestAdapter,
  execution_context_adapter: CodeMySpec.Support.RecordingExecutionContext,
  embeddings_backend: CodeMySpec.Embeddings.TestBackend,
  # Route ProjectUsers' outbound Req through Req.Test so specs/tests can stub
  # the target app's users endpoint without hitting the network.
  project_users_req_plug: {Req.Test, CodeMySpec.ProjectUsers}

# Tests write plans offline and deterministically. The LLM planner is the
# default everywhere else; here it would make every intake test a network call
# with a different answer each run.
config :code_my_spec, CodeMySpec.Intake,
  planner: CodeMySpec.Intake.Planner.Inferred,
  interviewer: CodeMySpec.Intake.Interviewer.Scripted,
  shaper: CodeMySpec.Intake.Shaper.Scripted

# Story 713: run content pull synchronously in tests so it shares the
# ExUnit sandbox connection instead of racing the test process.
config :code_my_spec, content_pull_async: false

# Story 841/5ff00ca3: run devops setup synchronously in tests, same reasoning
# — the spawned Task holds neither the Sandbox checkout nor Req.Test stub
# allowances the test process set up.
config :code_my_spec, provisioning_async: false

# Analysis runs execute inline (caller process) in tests: sandbox-owned DB
# connections, deterministic ordering, and the old synchronous stop-hook
# semantics for existing tests. The async ProjectServer path is exercised
# against the live dev server.
config :code_my_spec, analysis_mode: :inline

# `HarnessProjectChannel` gathers read-model pushes over this window; 2s in
# production.
config :code_my_spec, read_model_coalesce_ms: 50

# Static harness socket secret in tests — deterministic and avoids writing a
# generated secret into the developer's ~/.codemyspec on `mix test`.
config :code_my_spec, harness_secret: "test-harness-secret"
config :code_my_spec, :allow_spex_clock, true
config :code_my_spec, :provisioning_run_async, false
config :code_my_spec, :working_copies_app_run_async, false

# Provider OAuth client creds, so a spex recording can refresh a short-lived
# access token mid-run (Resend's live ~15 min, and verifying a sending domain
# polls longer). Env-sourced during recording; a placeholder otherwise, where
# no refresh is attempted because the fixture token reads as fresh.
config :code_my_spec,
  resend_client_id: System.get_env("RESEND_CLIENT_ID", "test-resend-client"),
  resend_client_secret: System.get_env("RESEND_CLIENT_SECRET", "test-resend-secret"),
  cloudflare_client_id: System.get_env("CLOUDFLARE_CLIENT_ID", "test-cloudflare-client"),
  cloudflare_client_secret: System.get_env("CLOUDFLARE_CLIENT_SECRET", "test-cloudflare-secret"),
  openai_client_id: System.get_env("OPENAI_CLIENT_ID", "test-openai-client")

# No network in tests. The target is a placeholder so the module has one to
# name; the Cloudflare calls themselves are cassette-backed where exercised.
config :code_my_spec, CodeMySpec.Workspaces.PreviewAddress,
  base_domain: "codemyspec.com",
  target: "test-tunnel.cfargotunnel.com"

# The tunnel provisioner reaches Cloudflare to create tunnels and write DNS.
# Pinned for the reason the GitHub client above is: `{Req.Test, Module}`
# dispatches to the calling process's stub, so tests stay async, and a call with
# no stub raises instead of provisioning a real tunnel on the real zone. An
# unpinned plug plus a token in the environment is a live call, which this
# project has shipped once already.
config :code_my_spec, CodeMySpec.Workspaces.PreviewTunnel,
  # Same-site with the preview domain, which is the property under test rather
  # than a value chosen for convenience. `PublicUrl.base()` would fall back to
  # `http://localhost:4002`, and localhost is a different registrable domain
  # from `codemyspec.com` — so the fallback describes a configuration that
  # cannot hold a session.
  embedder: "https://codemyspec.com",
  token: "test-cloudflare-token",
  zone_id: "test-zone",
  account_id: "test-account",
  req_options: [plug: {Req.Test, CodeMySpec.Workspaces.PreviewTunnel}]

# The pane re-checks a workspace that is still coming up. Short here so a spec
# observes the transition instead of waiting out the interval a visitor gets.
config :code_my_spec, CodeMySpecWeb.PreviewLive.Show, recheck_ms: 50

# The GitHub client's test plug, set once here rather than by each test.
#
# `{Req.Test, Module}` dispatches to whatever stub the *calling process* has
# registered, so two test files can drive the same client concurrently —
# which `Application.put_env` at runtime could not, being node-global. It was
# the shared key behind `git_hub_test` and `provisioning/repository_test`
# both having to be sync.
#
# A call with no stub registered raises rather than reaching GitHub, which is
# the behaviour wanted: a test that forgot to stub should say so.
config :code_my_spec, CodeMySpec.GitHub, plug: {Req.Test, CodeMySpec.GitHub}

config :code_my_spec, CodeMySpec.Provisioning.Tools.ConnectProvider,
  plug: {Req.Test, CodeMySpec.Provisioning.Tools.ConnectProvider}

# Every provider's /models answers 404 (an unknown list, allowed) unless a test
# installs a cassette: `Agents.ProviderModels`.
config :code_my_spec, CodeMySpec.Agents.ProviderModels,
  plug: CodeMySpecTest.UnlistedProviderModels

# `:dev_routes` is true here, so this LiveView's route exists in the test
# router — and its one request goes to the harness on :4004, which on a
# developer's box is the real one. Pinned so a test that mounts it reaches
# `Req.Test` instead of the machine.
config :code_my_spec, CodeMySpecWeb.DevAnalysisLive,
  plug: {Req.Test, CodeMySpecWeb.DevAnalysisLive}

# Loopback health probe. Unpinned, a test that passes a real port — 4000 is
# the obvious one — probes the running dev server and reads its answer as a
# workspace's health.
config :code_my_spec, CodeMySpec.Workspaces.Runner.Local,
  plug: {Req.Test, CodeMySpec.Workspaces.Runner.Local}

# Same reasoning, same pin: an unpinned health probe would hit whatever is
# actually listening on the port under test and read a real dev server's
# answer as this instance's health. Story 1108's own spex never exercise
# CmsHarness.AppInstance.Runner.Local directly (they run against
# CmsHarnessTest.FakeAppInstanceRunner instead — this project's no-live-
# shell-outs rule), so nothing stubs this plug today; it exists so this
# module is accounted for by `HttpClientsAreStubbableTest` and safe by
# construction if something ever does call it under test.
# Removing a checkout drops its databases on the machine's Postgres; under the
# suite nothing is found or dropped (`CmsHarness.CopyDatabases`).
config :code_my_spec, CmsHarness.CopyDatabases, runner: CmsHarnessTest.NoCopyDatabases

config :code_my_spec, CmsHarness.AppInstance.Runner.Local,
  plug: {Req.Test, CmsHarness.AppInstance.Runner.Local}

# The platform deploy key, set once so tests that need one present do not have
# to write it into application env themselves. `app_credential_test` and
# `content_sync_controller_test` both did, with different values, which is
# what pinned them together.
#
# `content_sync_controller_test` stays sync regardless: one of its tests
# deletes this key to assert the unconfigured refusal, and that is visible to
# the node however the value arrived.
config :code_my_spec, deploy_key: "test_platform_deploy_key"

# The Resend client, same arrangement as GitHub above. `mail_domain_test` and
# `mail_attachments_test` both wrote this key, so neither could be async.
#
# The api_key is here rather than per-test because it only has to be
# *present* — what each test varies is the response, and that is the plug.
# Unlike Hetzner, nothing outside these two files depends on Resend being
# unconfigured; the one test that does now lives in `mail_not_configured_test`.
config :code_my_spec, CodeMySpec.Mail.ResendClient,
  api_key: "re_test_key",
  plug: {Req.Test, CodeMySpec.Mail.ResendClient}

# Hetzner has no api_token here on purpose. `Hetzner.token/1` falls back to
# this key only after account and project secrets, so a token here would not
# configure one test — it would make every scope in the suite look configured,
# and the provisioning page's `reverify` would start really calling
# `list_servers/1`. `hetzner_test` puts its token in a project secret instead.
#
# The plug is safe to pin: `{Req.Test, Hetzner}` resolves per process, and a
# call with no stub raises rather than reaching Hetzner. Without it, a test
# that has a token but no stub makes a live request — which is exactly what
# happened while writing this.
config :code_my_spec, CodeMySpec.Provisioning.Hetzner,
  plug: {Req.Test, CodeMySpec.Provisioning.Hetzner}

# Every remaining Req client gets a test plug, for the same reason the three
# above have one: `{Req.Test, Mod}` resolves per process, so a stub set by one
# test is invisible to another, and a call with **no** stub raises instead of
# reaching the internet.
#
# That second half is the point of doing this in bulk. A client whose
# credential happens to be present and whose plug is unset makes a real
# request from the unit suite. It is not hypothetical: `hetzner_test` reached
# the live Hetzner API and came back `{:hetzner_error, 401, "the token you
# have provided is invalid"}` — a genuine reply from Hetzner, in a test whose
# subject was the *unconfigured* path.
#
# Pinning the plug does not configure a credential, so a client with no
# credential still short-circuits exactly as before.
# Both tools go out through `Research.Http`, so one plug covers search and fetch.
# The key is a literal so the provider resolves in test without an environment:
# without it every search test would exercise the "no provider" refusal instead
# of the thing it means to test.
config :code_my_spec, CodeMySpec.Research,
  plug: {Req.Test, CodeMySpec.Research},
  tavily_api_key: "test-key"

# Step 3's hex.pm client (577de9bb). Pinned so a reconciler test's own stub
# is the only way its fetch resolves — an unpinned client here would make a
# real request to repo.hex.pm the moment a test exercised it without
# remembering to stub first.
config :code_my_spec, CodeMySpec.Embeddings.HexPackageFetch,
  plug: {Req.Test, CodeMySpec.Embeddings.HexPackageFetch}

# Pasting a key asks the provider whether it works, and a suite that really
# asked would connect to Anthropic and Z.ai from every run of this story.
config :code_my_spec, CodeMySpec.Integrations.Providers.ApiKey,
  plug: {Req.Test, CodeMySpec.Integrations.Providers.ApiKey}

# Story 1116's ClickHouse telemetry reads (577de9bb's observability
# follow-on). Pinned for the same reason as every other provider client
# here — unset, a test that forgets to stub would reach a real host.
config :code_my_spec, CodeMySpec.Observability.ClickHouseClient,
  plug: {Req.Test, CodeMySpec.Observability.ClickHouseClient}

# list_projects calls the server's own /api/projects over HTTP rather than
# querying this database, so it is pinned like every client above.
config :code_my_spec, CodeMySpec.Bootstrap.Tools.ListProjects,
  plug: {Req.Test, CodeMySpec.Bootstrap.Tools.ListProjects}

config :code_my_spec, CodeMySpec.Mail.ImageProxy, plug: {Req.Test, CodeMySpec.Mail.ImageProxy}
config :code_my_spec, CodeMySpec.Google.Ads, plug: {Req.Test, CodeMySpec.Google.Ads}
config :code_my_spec, CodeMySpec.Google.Gsc, plug: {Req.Test, CodeMySpec.Google.Gsc}
config :code_my_spec, CodeMySpec.Google.Ga4, plug: {Req.Test, CodeMySpec.Google.Ga4}

# c1b2d03a: this mix task confirms an existing working copy's recorded id
# against the server before trusting it (`confirm/2`'s own `Req.get`).
# Hundreds of onboarding specs call it through `Mix.Task.run/2`, so an unset
# plug is a real request from the unit suite, same as every other client
# here.
config :code_my_spec, Mix.Tasks.Cms.Harness.Onboard,
  plug: {Req.Test, Mix.Tasks.Cms.Harness.Onboard}

# Story 1013: the mint POST itself, extracted into `CmsHarness.Onboarding`
# (criteria 916-918, so a spex could drive it in-process). Pinned
# separately from the mix task above -- different module, different Req
# call, now that the two are no longer the same piece of code.
config :code_my_spec, CmsHarness.Onboarding, plug: {Req.Test, CmsHarness.Onboarding}

config :code_my_spec, CodeMySpec.Provisioning.ContentPublishing,
  plug: {Req.Test, CodeMySpec.Provisioning.ContentPublishing}

config :code_my_spec, CodeMySpec.Provisioning.Cloudflare,
  plug: {Req.Test, CodeMySpec.Provisioning.Cloudflare}

config :code_my_spec, CodeMySpec.Provisioning.Deploy,
  plug: {Req.Test, CodeMySpec.Provisioning.Deploy}

config :code_my_spec, CodeMySpec.Provisioning.Widget,
  plug: {Req.Test, CodeMySpec.Provisioning.Widget}

config :code_my_spec, CodeMySpec.Provisioning.Resend,
  plug: {Req.Test, CodeMySpec.Provisioning.Resend}

config :code_my_spec, CodeMySpec.Provisioning.Deploy.UptimeRobot,
  plug: {Req.Test, CodeMySpec.Provisioning.Deploy.UptimeRobot}

config :code_my_spec, CodeMySpec.Content.TriggerClient,
  plug: {Req.Test, CodeMySpec.Content.TriggerClient}

config :code_my_spec, CodeMySpec.Content.CloudflareClient,
  plug: {Req.Test, CodeMySpec.Content.CloudflareClient}

config :code_my_spec, CodeMySpec.Content.PullClient,
  plug: {Req.Test, CodeMySpec.Content.PullClient}

config :code_my_spec, CodeMySpec.Content.S3Client, plug: {Req.Test, CodeMySpec.Content.S3Client}

config :code_my_spec, CodeMySpec.Uploads, plug: {Req.Test, CodeMySpec.Uploads}

config :code_my_spec, CodeMySpec.AgentHarness.ConversationRecorder,
  plug: {Req.Test, CodeMySpec.AgentHarness.ConversationRecorder}

config :code_my_spec, CodeMySpec.Billing.StripeClient,
  secret_key: "sk_test_spex",
  plug: {Req.Test, CodeMySpec.Billing.StripeClient}

# Static, not per-test: every spex reads the same fixture values, so setting
# them once here (rather than Application.put_env + on_exit-restore in every
# spex's own setup) removes a global-state race identical in shape to the
# one already fixed for :deploy_key (07c2c511) and the storage client
# (d0842eac4) -- the exact anti-pattern `choosing_a_test_seam.md` warns about
# under "Global state in tests": defined once, not read-and-restored.
config :code_my_spec, CodeMySpec.Billing,
  webhook_secret: "whsec_spex",
  light_price_id: "price_light_spex",
  pro_price_id: "price_pro_spex"

config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter,
  plug: {Req.Test, CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter}

# Never `~/.pi` — a test that minted a credential directory into the operator's
# real Pi configuration would be writing auth.json over their own.
config :code_my_spec,
       :pi_config_root,
       Path.join([System.tmp_dir!(), "codemyspec-test", "pi"])

# Never `~/.codemyspec/app-instances` — the same reasoning as `:pi_config_root`
# above, for story 1108's `CmsHarness.AppInstance`. Every `app_instance_rig`
# spex and test calls `persist!/1` on a successful start, and without this
# override each one wrote a real state dir onto the operator's own machine —
# 1,094 of them found on this one, with fake content like
# `{"os_pid":107,"port":4000,"database":"fakeapp_dev"}` sitting next to real
# app instances' own state, and a fake `os_pid` is not inert: `AppInstance`'s
# `:stop`/`:discard` handlers `kill -TERM` whatever `os_pid` a state file
# holds, and 107 was somebody else's real process. Static rather than a
# per-test dir for the same reason `:pi_config_root` is: every rig's root is
# already a fresh temp dir of its own (`instance_key/1` hashes it into a
# subdirectory), so nothing here collides even across concurrent worktrees
# sharing this one base path.
config :code_my_spec,
       :app_instances_root,
       Path.join([System.tmp_dir!(), "codemyspec-test", "app-instances"])

# Assent's HTTP adapter, pinned so an OAuth call in a test cannot leave the
# machine. Without this it defaults to a live adapter: story 1018's criterion
# 2822 reached `https://auth.openai.com/oauth/token` from the suite and came
# back with a real 401. A test holding a credential and an unpinned adapter is
# the same shape that once posted to real Google Analytics.
#
# `Req.Test` refuses an unstubbed call rather than performing it, so a test that
# needs an OAuth round trip has to say so — with `Req.Test.stub(Assent, …)` or
# through `OAuthSpexHelpers.with_assent_plug/2` and a cassette.
config :assent, http_adapter: {Assent.HTTPAdapter.Req, plug: {Req.Test, Assent}}

# The OpenAI device-login client, pinned like every other Req client here so a
# test cannot start a real login against somebody's ChatGPT account.
config :code_my_spec, CodeMySpec.Integrations.Providers.OpenAI.DeviceAuth,
  plug: {Req.Test, CodeMySpec.Integrations.Providers.OpenAI.DeviceAuth}

# Guided intake shapes inline in test: a task in another process cannot see
# the sandbox transaction, and an assertion on a race is not an assertion.
config :code_my_spec, intake_shaping_async: false

# Guided intake conversations run inline in test; ConversationTest exercises
# the real process with an explicit sandbox grant.
config :code_my_spec, intake_conversation_process: false

# A promotion's gate dispatches an analyzer sweep and waits for it. Nothing
# runs those analyzers in a spex — the checkouts are temp directories with no
# project — so the production default of two minutes is two minutes of nothing
# happening, per scenario. The bounded-wait behaviour is what the specs are
# about; the duration is not.
config :code_my_spec, :promotion_sweep_timeout, 200

# A promote whose restart acknowledgement is lost asks the app what it serves
# until this bound. Nothing answers in a test, so it gives up at once rather
# than outliving the test and logging into the next one.
config :code_my_spec, :promotion_verify_within, 0

# Dev-only routes are present in test so their wiring can be asserted.
#
# They are compile-gated to dev, which meant nothing ever tested that they are
# mounted — and a route that exists only where no test runs is a route whose
# wiring is checked by hand or not at all. The most expensive defect of
# 2026-09-12 was exactly that shape: `AgentScope` was in the hosted pipeline and
# not the local one, so every locally-run agent's question bypassed the main
# agent, and no test could have caught it because no test drove the pipeline.
#
# Enabling them here costs a few extra routes in the test router and buys the
# ability to assert that `/dev/sign-in` mints a token the product's own login
# route accepts — which is the only assertion that makes a dev sign-in helper
# trustworthy rather than a bypass.
config :code_my_spec, dev_routes: true

# Story 1070's behavioural evals, kept out of every ordinary run.
#
# They start real agents against a real model and measure what each one calls
# over ten runs, so one criterion is minutes rather than milliseconds. The
# promote gate gives every analyzer a deadline and a spex suite carrying these
# would never finish inside it — which would stop being a measurement and start
# being a wedge.
#
# `mix cms.eval` is how they run: it flips this and nothing else. `mix spex`
# has no `--include`, so the switch lives here rather than on a flag.
config :ex_unit, exclude: [:eval]

# How many times a behavioural criterion is measured. Ten is what the criteria
# state their thresholds against; lower it while writing one, and remember that
# a threshold asserted over two runs is a smoke test rather than a measurement.
config :code_my_spec, :agent_eval_runs, 10

# How long one measured turn may run before the run is abandoned. A real turn
# is a `claude` subprocess plus however many tool round trips the model makes,
# and a deadline that expires part-way through does not record a miss — it
# throws the run away.
config :code_my_spec, :agent_eval_settle_timeout, 300_000

# A stale eval artifact warns here rather than failing.
#
# The check is worth keeping: an artifact recorded against one prompt says
# nothing about a different one, and a green built on one is a latch. But
# failing on it red-lines all ten criteria for a reworded sentence, and a suite
# that goes red on every prompt edit is a suite people learn to skip. It also
# blocks unrelated work — four fixes the running fleet needed once sat behind a
# hundred re-recorded runs because `OperatingRules` had been trimmed.
#
# So the drift is still measured and still printed, naming the section and how
# far it moved; it just does not veto. Set `:fail` for a run that means to hold
# the artifacts to the shipped prompt, and `:ignore` to say nothing at all.
config :code_my_spec, :eval_artifact_staleness, :warn

# A test that exercises a result large enough to trip CodeMode.cap/2's spill
# (41bdee7d) must not write real files under the developer's actual home
# directory -- a disposable path under the test build's own tmp dir instead.
config :code_my_spec,
       :code_mode_spill_dir,
       Path.join(System.tmp_dir!(), "code_my_spec_test_spill")

# A test that runs a desktop OAuth connect must not open the machine's browser.
config :code_my_spec, CodeMySpec.Utils.Browser, launch: false

# Resend client registration (CodeMySpec.Integrations.DesktopClients) never reaches
# Resend from a test; tests stub it with Req.Test.
config :code_my_spec, CodeMySpec.Integrations.DesktopClients,
  plug: {Req.Test, CodeMySpec.Integrations.DesktopClients}

config :code_my_spec, CodeMySpec.Integrations.Providers.GitHub.DeviceAuth,
  plug: {Req.Test, CodeMySpec.Integrations.Providers.GitHub.DeviceAuth}

config :code_my_spec, CodeMySpec.Auth.HarnessOAuth, plug: {Req.Test, CodeMySpec.Auth.HarnessOAuth}

config :code_my_spec, CodeMySpecWeb.SourceGitController,
  plug: {Req.Test, CodeMySpecWeb.SourceGitController}

# The run guard watches this machine's ports and sweeps what dead BEAMs left. A
# test BEAM is neither: it polls only when a test asks, and records in its own
# directory, so it never reaps another harness's runs.
config :code_my_spec, CodeMySpec.RunGuard,
  poll_ms: :infinity,
  dir: Path.join([System.tmp_dir!(), "codemyspec-test", "runs"])

# Claude Code routines (story 1136): the fire call is answered by a stub.
config :code_my_spec, CodeMySpec.Devices.RoutineFire,
  plug: {Req.Test, CodeMySpec.Devices.RoutineFire}

# The suite on SQLite, the desktop's database: `just test-sqlite`. A separate
# build path, since the adapter is compile-time.
if System.get_env("CMS_TEST_SQLITE") do
  config :code_my_spec, adapter: Ecto.Adapters.SQLite3
  config :paper_trail, strict_mode: false

  config :code_my_spec, CodeMySpec.Repo,
    priv: "priv/sqlite",
    database: System.get_env("CMS_TEST_SQLITE"),
    pool: Ecto.Adapters.SQL.Sandbox,
    # One connection: SQLite has one writer, and two pooled connections each
    # holding a sandbox transaction fail each other's writes outright.
    pool_size: 1,
    journal_mode: :wal,
    busy_timeout: 10_000,
    default_transaction_mode: :immediate
end

# No minute-by-minute memory log line under test.
config :code_my_spec, :memory_report_period, false
