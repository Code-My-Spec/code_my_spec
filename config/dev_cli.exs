import Config

config :code_my_spec, env: :dev_cli

# SQLite adapter for CLI mode
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

config :code_my_spec, CodeMySpec.Repo,
  database: Path.expand("~/.codemyspec/cli.db"),
  pool_size: 1,
  busy_timeout: 10_000,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Disable the main web endpoint
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: false

# Local web endpoint (port 4003)
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  code_reloader: true,
  debug_errors: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:code_my_spec_local, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:code_my_spec_local, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/local/.*(js|css)$",
      ~r"lib/code_my_spec_local_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Dev logging
config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
