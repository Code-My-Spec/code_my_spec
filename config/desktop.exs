import Config

# desktop — the server and the light harness in one release on a developer's
# machine (bb8bc042). The prod server, the harness fragment, then what differs
# on a laptop. Runtime defaults (DATABASE_URL, secrets, OAuth) are in
# runtime.exs's desktop branch.
import_config "prod.exs"
import_config "harness_base.exs"

config :code_my_spec, env: :desktop, desktop_agent_transport: CodeMySpecDesktop.AgentTransport

# Ports of its own, so the desktop app runs beside a Phoenix app on 4000, a
# dev harness on 4004 and a brew `cms` on 4003 — a developer's machine has all
# three. 47400 is the app, 47403 its harness.
# 127.0.0.1, not localhost: Windows resolves localhost to ::1 first, and the
# endpoints listen on IPv4 only, so the harness never reached its server.
config :code_my_spec,
  api_base_url: "http://127.0.0.1:47400",
  oauth_base_url: "http://127.0.0.1:47400",
  base_url: "http://127.0.0.1:47400",
  harness_default_server_url: "http://127.0.0.1:47400"

# harness_base.exs turns the main endpoint off; here it is the product.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: true,
  url: [host: "127.0.0.1", port: 47_400, scheme: "http"],
  http: [ip: {127, 0, 0, 1}, port: 47_400],
  check_origin: false

# The harness's server is this BEAM, so its device grant is approved for the
# desktop user without anyone typing a code.
config :code_my_spec, harness_device_approver: {CodeMySpecDesktop.HarnessApproval, :approve}

# config.exs leaves it `server: false`; desktop's harness serves hooks.
config :code_my_spec, CmsHarness.Web.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 47_403]

# SQLite: nothing to install before the app runs. Its own migrations, from a
# baseline of the Postgres schema (priv/sqlite).
config :code_my_spec, adapter: Ecto.Adapters.SQLite3
config :code_my_spec, CodeMySpec.Repo, priv: "priv/sqlite"
config :paper_trail, strict_mode: false

# Served over http://localhost. WebKit (the desktop window) drops a `secure`
# cookie there, so LiveView never saw a session and reloaded ~50 times a second.
config :code_my_spec, secure_session_cookie: false

# Integration clients made for an app with no server secret, baked in at build
# time (CodeMySpec.Integrations.DesktopClients). Google's "Desktop app" secret is not
# confidential by Google's own definition; it still comes from sops/CI secrets
# rather than the repo. Cloudflare's client is public: an id, no secret.
config :code_my_spec, :desktop_oauth_clients,
  google_client_id: System.get_env("GOOGLE_DESKTOP_CLIENT_ID", ""),
  google_client_secret: System.get_env("GOOGLE_DESKTOP_CLIENT_SECRET", ""),
  cloudflare_client_id: "2fa2730e477ff5f0bbb13d013400ee46",
  # The dev GitHub OAuth app, device flow enabled. Public: device flow uses no secret.
  github_client_id: "Ov23liFpnT7j3bK5OC1L"

config :desktop, :backend, DesktopWebview.Backend
config :desktop, :menu_adapter, DesktopWebview.Menu.Adapter

# Mail stays in memory (config.exs's Local adapter); prod.exs turned the store off.
config :swoosh, local: true
