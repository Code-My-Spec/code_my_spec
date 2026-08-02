import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :code_my_spec, CodeMySpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "code_my_spec_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# server: false — Phoenix.ConnTest and LiveViewTest do not go through HTTP,
# so nothing here needs a listener. It was true only for Wallaby, which is no
# longer a dependency and whose test/e2e directory no longer exists.
#
# Binding the port had a real cost: every `mix test` and `mix run` grabbed
# 4002, so a concurrent background analysis run (the stop hook enqueues a full
# `mix spex`) failed the other with :eaddrinuse. Same reasoning as the
# LocalWeb endpoint below, which has always been server: false.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "uQsFkBLrXNG5yxrQkMHNLOAi5NcrEzpZut3YYEOlAFiuhpoynMd+/rJBgz6FSWsg",
  server: false

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
