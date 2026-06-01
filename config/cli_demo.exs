import Config

config :code_my_spec, env: :cli_demo

# Sealed demo harness. Points at the local demo *server* (config/demo.exs on
# :4006), never dev/prod, so a session replay can rebuild a project from
# scratch without touching real data. If the demo server is not running,
# local CRUD / MCP still works — only sync/auth would no-op.
config :code_my_spec,
  api_base_url: "http://localhost:4006",
  oauth_base_url: "http://localhost:4006",
  base_url: "http://localhost:4006"

# PaperTrail strict_mode uses Postgres sequences — SQLite doesn't have them.
config :paper_trail, strict_mode: false

config :code_my_spec, stories_implementation: CodeMySpec.Stories.StoriesRepository
config :code_my_spec, personas_implementation: CodeMySpec.Personas.PersonasRepository
config :code_my_spec, bdd_rules_implementation: CodeMySpec.BddRules.BddRulesRepository
config :code_my_spec, questions_implementation: CodeMySpec.Questions.QuestionsRepository

config :code_my_spec,
  acceptance_criteria_implementation: CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository

# SQLite adapter for CLI mode
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

# Embedding pipeline lives in CLI builds (Ortex + sqlite_vec).
config :code_my_spec, embeddings_backend: CodeMySpec.Embeddings.SqliteVecBackend

# `database` is set in runtime.exs (~/.codemyspec/cli_demo.db) so `~` expands
# on the user's machine and the demo DB can never collide with cli_dev.db.
config :code_my_spec, CodeMySpec.Repo,
  pool_size: 1,
  busy_timeout: 10_000,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Disable the main web endpoint — the local harness endpoint is the surface.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: false

# Local harness endpoint — :4005 so the demo coexists with the real dev_cli
# app on :4004 and the published `cms` binary on :4003.
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4005],
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

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false

# No Cloudflare tunnel: tunnel_children/0 only starts for env == :dev_cli, so
# a :cli_demo boot is private-by-construction — nothing leaves localhost.
