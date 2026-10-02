import Config

# desktop — the server and the light harness in one release on a developer's
# machine (bb8bc042). The prod server, the harness fragment, then what differs
# on a laptop. Runtime defaults (DATABASE_URL, secrets, OAuth) are in
# runtime.exs's desktop branch.
import_config "prod.exs"
import_config "harness.exs"

config :code_my_spec, env: :desktop

config :code_my_spec,
  api_base_url: "http://localhost:4000",
  oauth_base_url: "http://localhost:4000",
  base_url: "http://localhost:4000",
  harness_default_server_url: "http://localhost:4000"

# harness.exs turns the main endpoint off; here it is the product.
config :code_my_spec, CodeMySpecWeb.Endpoint,
  server: true,
  url: [host: "localhost", port: 4000, scheme: "http"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false

# config.exs leaves it `server: false`; desktop's harness serves hooks.
config :code_my_spec, CmsHarness.Web.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4004]

# Postgres, not harness.exs's SQLite — same reversal as dev_sprite.
config :code_my_spec, adapter: Ecto.Adapters.Postgres
config :paper_trail, strict_mode: true

# Embeddings off unless runtime.exs turns them on (CMS_EMBEDDINGS); they need
# pgvector, which a local Postgres may not have.
config :code_my_spec, embeddings_backend: nil

# Mail stays in memory (config.exs's Local adapter); prod.exs turned the store off.
config :swoosh, local: true
