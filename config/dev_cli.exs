import Config

config :code_my_spec, env: :dev_cli

# Dev_cli build talks to dev so the in-repo CLI workflow exercises the
# dev server, not prod. See prod_cli.exs for why three keys.
config :code_my_spec,
  api_base_url: "https://dev.codemyspec.com",
  oauth_base_url: "https://dev.codemyspec.com",
  base_url: "https://dev.codemyspec.com"

# Framework-scoped issues route to the CodeMySpec project on the dev server,
# not the user's active project. Sent via the `x-project-id` header by
# Issues.RemoteClient.create_issue/3.
config :code_my_spec, code_my_spec_project_id: "708492f9-454e-482f-a2eb-be64f0356b87"

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
#
# pool_size 5 (was 1): background analysis reconciles run concurrently with
# hook requests and LiveViews — one connection made everything queue behind a
# long write transaction. `:immediate` transactions because the default
# `:deferred` mode can't upgrade read→write when another connection committed
# meanwhile — SQLite returns SQLITE_BUSY instantly (snapshot invalidation)
# and busy_timeout does NOT cover that case.
config :code_my_spec, CodeMySpec.Repo,
  pool_size: 5,
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Disable the main web endpoint
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: false

# Local web endpoint — runs on 4004 in dev_cli so an in-repo CLI build
# can coexist with the published `cms` binary on 4003.
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4004],
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

# Cloudflare Tunnel — quick mode. Boots a *.trycloudflare.com URL
# pointing at the local server on :4004 (no account or DNS required).
config :code_my_spec, :cloudflare_tunnel,
  mode: :quick,
  origin_url: "http://127.0.0.1:4004"
config :code_my_spec, :mcp_relay_base_url, "http://localhost:4004"
