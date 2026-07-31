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

config :code_my_spec, CodeMySpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database:
    if(e2e?,
      do: "code_my_spec_e2e",
      else: "code_my_spec_test#{System.get_env("MIX_TEST_PARTITION")}"
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

# In test we don't send emails
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

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
  issues_remote_client: CodeMySpec.Issues.RemoteClientStub,
  # Route ProjectUsers' outbound Req through Req.Test so specs/tests can stub
  # the target app's users endpoint without hitting the network.
  project_users_req_plug: {Req.Test, CodeMySpec.ProjectUsers}

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
