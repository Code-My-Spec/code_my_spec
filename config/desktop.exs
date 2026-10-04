import Config

# desktop — the server and the light harness in one release on a developer's
# machine (bb8bc042). The prod server, the harness fragment, then what differs
# on a laptop. Runtime defaults (DATABASE_URL, secrets, OAuth) are in
# runtime.exs's desktop branch.
import_config "prod.exs"
import_config "harness_base.exs"

config :code_my_spec, env: :desktop

config :code_my_spec,
  api_base_url: "http://localhost:4000",
  oauth_base_url: "http://localhost:4000",
  base_url: "http://localhost:4000",
  harness_default_server_url: "http://localhost:4000"

# harness_base.exs turns the main endpoint off; here it is the product.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: true,
  url: [host: "localhost", port: 4000, scheme: "http"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false

# config.exs leaves it `server: false`; desktop's harness serves hooks.
config :code_my_spec, CmsHarness.Web.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4004]

# Postgres, not harness_base.exs's SQLite.
config :code_my_spec, adapter: Ecto.Adapters.Postgres
config :paper_trail, strict_mode: true

# Served over http://localhost. WebKit (the desktop window) drops a `secure`
# cookie there, so LiveView never saw a session and reloaded ~50 times a second.
config :code_my_spec, secure_session_cookie: false

# Integration clients made for an app with no server secret, baked in at build
# time (CodeMySpecDesktop.OAuthClients). Google's "Desktop app" secret is not
# confidential by Google's own definition; it still comes from sops/CI secrets
# rather than the repo. Cloudflare's client is public: an id, no secret.
config :code_my_spec, :desktop_oauth_clients,
  google_client_id: System.get_env("GOOGLE_DESKTOP_CLIENT_ID", ""),
  google_client_secret: System.get_env("GOOGLE_DESKTOP_CLIENT_SECRET", ""),
  cloudflare_client_id: "2fa2730e477ff5f0bbb13d013400ee46"

config :desktop, :backend, DesktopWebview.Backend
config :desktop, :menu_adapter, DesktopWebview.Menu.Adapter

# Mail stays in memory (config.exs's Local adapter); prod.exs turned the store off.
config :swoosh, local: true
