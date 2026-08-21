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
  pool:
    if(e2e? or drill_db?,
      do: DBConnection.ConnectionPool,
      else: Ecto.Adapters.SQL.Sandbox
    ),
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

# Story 841/5ff00ca3: run devops setup synchronously in tests, same reasoning
# — the spawned Task holds neither the Sandbox checkout nor Req.Test stub
# allowances the test process set up.
config :code_my_spec, provisioning_async: false

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

# Loopback health probe. Unpinned, a test that passes a real port — 4000 is
# the obvious one — probes the running dev server and reads its answer as a
# workspace's health.
config :code_my_spec, CodeMySpec.Workspaces.Runner.Local,
  plug: {Req.Test, CodeMySpec.Workspaces.Runner.Local}


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
config :code_my_spec, CodeMySpec.Mail.ImageProxy, plug: {Req.Test, CodeMySpec.Mail.ImageProxy}
config :code_my_spec, CodeMySpec.Google.Ads, plug: {Req.Test, CodeMySpec.Google.Ads}
config :code_my_spec, CodeMySpec.Google.Gsc, plug: {Req.Test, CodeMySpec.Google.Gsc}
config :code_my_spec, CodeMySpec.Google.Ga4, plug: {Req.Test, CodeMySpec.Google.Ga4}

config :code_my_spec, CodeMySpec.Provisioning.ContentPublishing,
  plug: {Req.Test, CodeMySpec.Provisioning.ContentPublishing}

config :code_my_spec, CodeMySpec.Provisioning.Cloudflare,
  plug: {Req.Test, CodeMySpec.Provisioning.Cloudflare}

config :code_my_spec, CodeMySpec.Provisioning.Deploy, plug: {Req.Test, CodeMySpec.Provisioning.Deploy}
config :code_my_spec, CodeMySpec.Provisioning.Widget, plug: {Req.Test, CodeMySpec.Provisioning.Widget}
config :code_my_spec, CodeMySpec.Provisioning.Resend, plug: {Req.Test, CodeMySpec.Provisioning.Resend}

config :code_my_spec, CodeMySpec.Provisioning.Deploy.UptimeRobot,
  plug: {Req.Test, CodeMySpec.Provisioning.Deploy.UptimeRobot}

config :code_my_spec, CodeMySpec.Content.TriggerClient,
  plug: {Req.Test, CodeMySpec.Content.TriggerClient}

config :code_my_spec, CodeMySpec.Content.CloudflareClient,
  plug: {Req.Test, CodeMySpec.Content.CloudflareClient}

config :code_my_spec, CodeMySpec.Content.PullClient, plug: {Req.Test, CodeMySpec.Content.PullClient}
config :code_my_spec, CodeMySpec.Content.S3Client, plug: {Req.Test, CodeMySpec.Content.S3Client}

config :code_my_spec, CodeMySpec.AgentHarness.ConversationRecorder,
  plug: {Req.Test, CodeMySpec.AgentHarness.ConversationRecorder}

config :code_my_spec, CodeMySpec.Billing.StripeClient,
  plug: {Req.Test, CodeMySpec.Billing.StripeClient}

config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter,
  plug: {Req.Test, CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter}
