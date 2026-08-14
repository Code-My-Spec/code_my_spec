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
partition =
  System.get_env("MIX_TEST_PARTITION") ||
    if File.regular?(Path.join(File.cwd!(), ".git")),
      do: "_" <> Path.basename(File.cwd!()),
      else: ""

config :code_my_spec, CodeMySpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database:
    if(e2e?,
      do: "code_my_spec_e2e",
      else: "code_my_spec_test#{partition}"
    ),
  # The sandbox owns connections per test process and hands nothing to an
  # external client, so an out-of-process harness cannot see anything a
  # sandboxed pool writes.
  pool: if(e2e?, do: DBConnection.ConnectionPool, else: Ecto.Adapters.SQL.Sandbox),
  pool_size: System.schedulers_online() * 2

# server: false — Phoenix.ConnTest and LiveViewTest do not go through HTTP,
# so nothing here needs a listener. It was true only for Wallaby, which is no
# longer a dependency and whose test/e2e directory no longer exists.
#
# Binding the port had a real cost: every `mix test` and `mix run` grabbed
# 4002, so a concurrent background analysis run (the stop hook enqueues a full
# `mix spex`) failed the other with :eaddrinuse. Same reasoning as the
# LocalWeb endpoint below, which has always been server: false.
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

# Local web endpoint — needed for spex tests that drive the local UI.
# server: false, runs as a started-but-quiet endpoint so LiveViewTest can use it.
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4004],
  secret_key_base: "uQsFkBLrXNG5yxrQkMHNLOAi5NcrEzpZut3YYEOlAFiuhpoynMd+/rJBgz6FSWsg",
  server: false

# Light harness endpoint. A port of its own so a test run cannot talk to — or be
# talked to by — a `cms harness` someone left running on 4005.
config :code_my_spec, CmsHarness.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4105],
  server: false

# The real values are 10s and 2s; the behaviours under test are the same at a
# tenth of that, and the suite would otherwise spend most of its time waiting
# for timers it already knows the shape of.
#
# `remote_await_timeout` is 31 minutes in production — a whole suite on a cold
# `_build`. At that length a test that dispatches a run and ends leaves the
# waiting task alive for half an hour, and the harness-never-answered path
# cannot be asserted at all.
config :code_my_spec,
  harness_decision_timeout: 1_000,
  harness_watch_debounce_ms: 200,
  remote_await_timeout: 500

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
  environment: CodeMySpec.Support.RecordingEnvironment,
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

# Analysis runs execute inline (caller process) in tests: sandbox-owned DB
# connections, deterministic ordering, and the old synchronous stop-hook
# semantics for existing tests. The async ProjectServer path is exercised
# against the live dev server.
config :code_my_spec, analysis_mode: :inline

# Static harness socket secret in tests — deterministic and avoids writing a
# generated secret into the developer's ~/.codemyspec on `mix test`.
config :code_my_spec, harness_secret: "test-harness-secret"
config :code_my_spec, :allow_spex_clock, true
config :code_my_spec, :provisioning_run_async, false

# Provider OAuth client creds, so a spex recording can refresh a short-lived
# access token mid-run (Resend's live ~15 min, and verifying a sending domain
# polls longer). Env-sourced during recording; a placeholder otherwise, where
# no refresh is attempted because the fixture token reads as fresh.
config :code_my_spec,
  resend_client_id: System.get_env("RESEND_CLIENT_ID", "test-resend-client"),
  resend_client_secret: System.get_env("RESEND_CLIENT_SECRET", "test-resend-secret"),
  cloudflare_client_id: System.get_env("CLOUDFLARE_CLIENT_ID", "test-cloudflare-client"),
  cloudflare_client_secret: System.get_env("CLOUDFLARE_CLIENT_SECRET", "test-cloudflare-secret")

# No network in tests. The target is a placeholder so the module has one to
# name; the Cloudflare calls themselves are cassette-backed where exercised.
config :code_my_spec, CodeMySpec.Workspaces.PreviewAddress,
  base_domain: "codemyspec.com",
  target: "test-tunnel.cfargotunnel.com"

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


# The platform deploy key, set once so tests that need one present do not have
# to write it into application env themselves. `app_credential_test` and
# `content_sync_controller_test` both did, with different values, which is
# what pinned them together.
#
# `content_sync_controller_test` stays sync regardless: one of its tests
# deletes this key to assert the unconfigured refusal, and that is visible to
# the node however the value arrived.
config :code_my_spec, deploy_key: "test_platform_deploy_key"
