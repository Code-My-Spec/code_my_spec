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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
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
  github_client_id: "test_github_client_id",
  github_client_secret: "test_github_client_secret",
  git_impl_module: CodeMySpec.Support.TestAdapter,
  environment: CodeMySpec.Support.RecordingEnvironment
