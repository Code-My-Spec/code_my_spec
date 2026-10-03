import Config
import_config "harness_base.exs"

# The harness: `just harness` in dev and the `cms_harness` release that
# brew and the MSI install. One env for both — what differs between a dev
# harness and an installed one is set by environment variables in
# runtime.exs (`CMS_SERVER_URL`, `CMS_ANALYSIS_SLOTS`, `CMS_HARNESS_PORT`),
# not by a second build.

config :code_my_spec, env: :harness

# Framework-scoped issues (friction with CodeMySpec itself) route to the
# CodeMySpec project on the server, not the user's active project.
config :code_my_spec, code_my_spec_project_id: "a3158f01-3008-4394-b9d1-669236a358c8"

# Use the Req-backed Swoosh client (Req is already a dep). Without this, Swoosh
# defaults to Swoosh.ApiClient.Hackney — hackney isn't a dep, so boot crashes.
config :swoosh, api_client: Swoosh.ApiClient.Req

# For `cms migrate`, the only boot that starts the Repo. `database` is set in
# runtime.exs so `~` expands on the user's machine, not the CI builder's.
# `:immediate` transactions: the default `:deferred` mode can't upgrade
# read→write when another connection committed meanwhile, and busy_timeout
# does not cover that case.
config :code_my_spec, CodeMySpec.Repo,
  pool_size: 5,
  busy_timeout: 10_000,
  default_transaction_mode: :immediate,
  log: false

# 4003 is the port the published plugin names (rewritten from the source tree's
# 4004 by `mix cms.package_plugin`). `just harness` sets CMS_HARNESS_PORT=4004.
config :code_my_spec, CmsHarness.Web.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4003]

# Harness logging goes to ~/.codemyspec/harness.log via the handler
# `CmsHarness.Application` installs; this is the level for everything else.
config :logger, level: :info
