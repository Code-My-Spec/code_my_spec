import Config

# dev_sprite — the harness, on centralized data.
#
# Same code as dev_cli. The difference is where the model lives: dev_cli
# keeps a complete SQLite database per working copy, dev_sprite points the
# same Repo at the central Postgres and keeps nothing locally.
#
# That is the whole change. A live diff of the two schemas came back with one
# table (doc_embeddings, added in 20260729010000), so there is no split model
# and no synchronization — the sprite reads and writes the same rows the web
# UI renders.
#
# What follows from it:
#
#   * The sprite is stateless. No volume, no backups, no lease, no
#     checkout-to-one-place. Destroy one mid-run and lose nothing but a
#     working copy that is already in git.
#   * It holds no data at rest, so a compromised sprite yields one scoped
#     credential rather than a project's database.
#   * Concurrency stops being a design constraint — two sprites on one
#     project is two Postgres connections.
#
# Offline is what you give up, which is why dev_cli still exists: a desktop
# install stays local-first on SQLite. Identical schema, different adapter.

config :code_my_spec, env: :dev_sprite

config :code_my_spec,
  api_base_url: "https://dev.codemyspec.com",
  oauth_base_url: "https://dev.codemyspec.com",
  base_url: "https://dev.codemyspec.com"

config :code_my_spec, code_my_spec_project_id: "708492f9-454e-482f-a2eb-be64f0356b87"

config :code_my_spec, stories_implementation: CodeMySpec.Stories.StoriesRepository
config :code_my_spec, personas_implementation: CodeMySpec.Personas.PersonasRepository
config :code_my_spec, bdd_rules_implementation: CodeMySpec.BddRules.BddRulesRepository
config :code_my_spec, questions_implementation: CodeMySpec.Questions.QuestionsRepository

config :code_my_spec,
  acceptance_criteria_implementation: CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository

# Postgres, not SQLite. This line is the entire architectural difference.
config :code_my_spec, adapter: Ecto.Adapters.Postgres

# PaperTrail strict_mode was disabled on the CLI only because SQLite has no
# sequences. On Postgres it can run as it does on the server.
config :paper_trail, strict_mode: true

# pgvector rather than sqlite_vec — see the doc_embeddings migration.
config :code_my_spec, embeddings_backend: CodeMySpec.Embeddings.PgVectorBackend

# Connection details come from runtime.exs so one image can be pointed at a
# different database without a rebuild.
#
# pool_size is deliberately small. A sprite is one agent doing one project's
# work, and the sprite role should carry a CONNECTION LIMIT on the Postgres
# side as well — that pair is what keeps a runaway sprite from starving the
# app server, and is why sprites do not need their own instance to start with.
config :code_my_spec, CodeMySpec.Repo,
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# No public web surface. The sprite is reached only by the agent on loopback
# and by whatever launched it, over an outbound connection. The user-facing
# UI is served by the server against the same rows.
config :code_my_spec, CodeMySpecWeb.Endpoint, server: false

config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  check_origin: false,
  debug_errors: true

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# A sprite sends no mail; the server does. Same as the other CLI-side envs.
config :swoosh, :api_client, false
