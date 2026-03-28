import Config

config :code_my_spec, env: :prod_cli

# SQLite adapter for CLI mode
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

config :code_my_spec, CodeMySpec.Repo,
  database: Path.expand("~/.codemyspec/cli.db"),
  pool_size: 5,
  busy_timeout: 10_000,
  log: false

# Disable the main web endpoint
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: false

# Local web endpoint (port 4003)
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  code_reloader: false,
  check_origin: false

# Disable console logging to prevent cluttering the TUI
config :logger, :default_handler, false

# Do not print debug messages in production
config :logger, level: :info
