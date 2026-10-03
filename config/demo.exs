import Config
import_config "dev_tooling.exs"

config :code_my_spec, env: :demo

# Isolated demo server — its own Postgres DB and port (:4006) so a session
# replay's sync/auth target is fully separate from dev (:4000) and prod.
# Needs envs/demo.env for GITHUB_CLIENT_ID / GOOGLE_CLIENT_ID / DEPLOY_KEY
# (see runtime.exs web block). Boot only when the replay needs the backend.
config :code_my_spec, CodeMySpec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "code_my_spec_demo",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :code_my_spec, CodeMySpecWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4006")],
  url: [host: "localhost", scheme: "http", port: 4006],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "zAdDnosjD+RybgufB/tmfEF9HrzOzapEfAlY1eLu+bkx4BLAUatnvNlUHP103p2S",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:code_my_spec, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:code_my_spec, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/code_my_spec_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :code_my_spec, dev_routes: true

# No Cloudflare tunnel: the web app only starts one for env == :dev
# (CodeMySpecWeb.Application.children/2). :demo hits the catch-all — private.
