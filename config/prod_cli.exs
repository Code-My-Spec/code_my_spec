import Config

config :code_my_spec, env: :prod_cli
config :code_my_spec, stories_implementation: CodeMySpec.Stories.RemoteClient
config :code_my_spec, personas_implementation: CodeMySpec.Personas.RemoteClient

config :code_my_spec,
  acceptance_criteria_implementation: CodeMySpec.AcceptanceCriteria.RemoteClient

# SQLite adapter for CLI mode
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

# `database` is set in runtime.exs so `~` expands on the user's machine,
# not the CI builder's ($HOME = /Users/runner in GitHub Actions).
config :code_my_spec, CodeMySpec.Repo,
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

# Default handler writes to stderr. `cms server` is always daemonized via
# `nohup cms server >>~/.codemyspec/server.log 2>&1`, so stderr lands in
# server.log and `cms logs` can show it. Previously we disabled the handler
# to keep the TUI clean — but the TUI is moot once daemonized, and without
# any handler every error in the prod binary was invisible.
config :logger, level: :info
