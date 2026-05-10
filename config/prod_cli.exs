import Config

config :code_my_spec, env: :prod_cli

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

# Logger handler is installed at runtime by CodeMySpec.Logging — :default_handler
# is swapped for a :logger_std_h writing logfmt to ~/.codemyspec/server.log with
# rotation (10 MB × 3). Daemon shell-redirects stdout/stderr to a separate
# ~/.codemyspec/server.boot.log so BEAM startup junk doesn't interleave with
# the rotated structured log.
config :logger, level: :info
config :code_my_spec, install_file_logger: true
