import Config

config :code_my_spec, env: :dev_cli

# PaperTrail strict_mode uses Postgres sequences — SQLite doesn't have them.
# Disable on the local CLI deployment; versions are still recorded but
# `first_version_id` / `current_version_id` columns stay nil.
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

# `database` is set in runtime.exs so `~` expands on the user's machine.
config :code_my_spec, CodeMySpec.Repo,
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
