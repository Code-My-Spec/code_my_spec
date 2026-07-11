import Config

config :code_my_spec, env: :prod_cli

# Shipped binary talks to prod. All three URL keys exist because different
# call sites read different ones: OAuth registration reads :oauth_base_url,
# OAuthClient.get_server_url + IssuesClient read :base_url, MCP-side flows
# read :api_base_url.
config :code_my_spec,
  api_base_url: "https://codemyspec.com",
  oauth_base_url: "https://codemyspec.com",
  base_url: "https://codemyspec.com"

# Framework-scoped issues (friction with CodeMySpec itself) route to the
# CodeMySpec project on the server, not the user's active project. Sent via the
# `x-project-id` header by Issues.RemoteClient.create_issue/3 on the legacy
# OAuth fallback path.
config :code_my_spec, code_my_spec_project_id: "a3158f01-3008-4394-b9d1-669236a358c8"

# That project's deploy key (projects.deploy_key — widget semantics: the
# blind-index hash resolves the project from the key alone). Preferred auth
# for framework issues: POST /api/framework/issues works with no OAuth
# connection, the local-first default.
config :code_my_spec,
  framework_deploy_key:
    "7975bd37545f1ee2835ce26a6e1e4998362296ae5a193e32756d40a05db2de52718a79bd6e4360b80a6128fb9c983d2f7de1e0ef73df2499b24d514ddb1137d7"

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

# Use the Req-backed Swoosh client (Req is already a dep). Without this, Swoosh
# defaults to Swoosh.ApiClient.Hackney — hackney isn't a dep, so boot crashes.
config :swoosh, api_client: Swoosh.ApiClient.Req

# SQLite adapter for CLI mode
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

# Embedding pipeline lives in CLI builds (Ortex + sqlite_vec).
config :code_my_spec, embeddings_backend: CodeMySpec.Embeddings.SqliteVecBackend

# `database` is set in runtime.exs so `~` expands on the user's machine,
# not the CI builder's ($HOME = /Users/runner in GitHub Actions).
# `:immediate` transactions: the default `:deferred` mode can't upgrade
# read→write when another connection committed meanwhile — SQLite returns
# SQLITE_BUSY instantly and busy_timeout does NOT cover that case. Matters
# now that background analysis reconciles write concurrently with requests.
config :code_my_spec, CodeMySpec.Repo,
  pool_size: 5,
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
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
