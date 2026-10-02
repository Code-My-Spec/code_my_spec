import Config
import_config "harness.exs"
import_config "dev_tooling.exs"

config :code_my_spec, env: :dev_cli

# Dev_cli build talks to dev so the in-repo CLI workflow exercises the
# dev server, not prod. See prod_cli.exs for why three keys.
config :code_my_spec,
  api_base_url: "https://dev.codemyspec.com",
  oauth_base_url: "https://dev.codemyspec.com",
  base_url: "https://dev.codemyspec.com"

# The server a harness in this build reports to when CMS_SERVER_URL and
# :harness_server_url say nothing. Same server as the rest of the build.
config :code_my_spec, harness_default_server_url: "https://dev.codemyspec.com"

# Framework-scoped issues route to the CodeMySpec project on the dev server,
# not the user's active project. Sent via the `x-project-id` header by
# Issues.RemoteClient.create_issue/3 over the CLI's OAuth session.
config :code_my_spec, code_my_spec_project_id: "708492f9-454e-482f-a2eb-be64f0356b87"

# `AnalysisSlots.limit/0` defaults to a fourth of the cores -- 2 on this
# box's 10 schedulers. Its own moduledoc already names the risk: each `mix
# test`/`mix spex` sets `max_cases` to twice the scheduler count on its
# own, so two concurrent slots alone can want up to 40 concurrent
# OS-thread-equivalents on 10 cores. Measured live, 2026-09-15: spex runs
# executing alone finished in 400-500s; two running at once (both slots
# held) took 650-990s each -- worse than serializing them would have, and
# exactly the "manufactured failures" the moduledoc warns oversubscription
# causes (a heavy test dies mid-run, passes clean in isolation).
#
# This box runs the one shared dev_cli harness for every worktree
# checkout of this repo, so it is the one machine where multiple full
# suites are ever actually concurrent. Scoped here rather than changed as
# the general default: a typical `cms harness` install serves one
# project, with no sibling suite to contend with, so the tradeoff this
# box needs does not apply there.
config :code_my_spec, analysis_slots: 1

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

# The harness's own endpoint (`just harness`, port 4004 by default — see
# CodeMySpecLocalWeb.Application.start_harness/0, which is what this build
# actually boots; CodeMySpecLocalWeb.Endpoint below is compiled in but never
# started from here). `code_reloader: true` recompiles changed modules,
# including a changed router, on the next request — without this, every
# code change to lib/cms_harness/** needed `just refresh-harness` to show up.
#
# Off: a promote merges into the checkout this harness runs from, and the next
# hook request hot-swapped lib/cms_harness under live processes, crashing the
# channel carrying the restart (08744186). Promotion restarts the harness
# instead; in dev, `just refresh-harness` picks up a harness change.
config :code_my_spec, CmsHarness.Web.Endpoint,
  # code_reloader: true,
  debug_errors: true

# Local web endpoint — compiled for this env but not started by
# `start_harness/0`; kept configured so `mix cms.new`/tests that reach it
# directly still work. Runs on 4004 only when something explicitly starts
# it, which in dev_cli practice is nothing.
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

# Cloudflare Tunnel — quick mode. Boots a *.trycloudflare.com URL
# pointing at the local server on :4004 (no account or DNS required).
config :code_my_spec, :cloudflare_tunnel,
  mode: :quick,
  origin_url: "http://127.0.0.1:4004"

config :code_my_spec, :mcp_relay_base_url, "http://localhost:4004"
