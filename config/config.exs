# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :code_my_spec, :scopes,
  user: [
    default: true,
    module: CodeMySpec.Users.Scope,
    assign_key: :current_scope,
    access_path: [:active_account, :id],
    schema_key: :account_id,
    schema_type: :id,
    schema_table: :accounts,
    test_data_fixture: CodeMySpec.UsersFixtures,
    test_setup_helper: :register_log_in_setup_account
  ]

config :code_my_spec,
  ecto_repos: [CodeMySpec.Repo],
  generators: [timestamp_type: :utc_datetime]

# Google OAuth scopes requested on the consent screen. Default to the
# non-sensitive scopes only (no app-verification required). Environments
# where the app is verified (or under test) add sensitive scopes such as
# `https://www.googleapis.com/auth/adwords` — see config/dev.exs.
config :code_my_spec, google_oauth_scopes: "email profile"

# Cloudflare issues a refresh token only when the OAuth client was *created*
# with `refresh_token` among its grant types — it then adds `offline_access`
# to the client's scopes itself. Without it a grant simply dies at its expiry
# (~16h) with nothing to renew from, which is survivable interactively and a
# real hazard for an unattended provisioning run.
#
# On for the client in `envs/.env`, which was created with both grant types.
# A client created without them must set this to false or connecting fails
# outright with invalid_scope.
config :code_my_spec, :cloudflare_offline_access, true

# Configures the endpoint
config :code_my_spec, CodeMySpecWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CodeMySpecWeb.ErrorHTML, json: CodeMySpecWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CodeMySpec.PubSub,
  live_view: [signing_salt: "WM19jFVv"]

# Configures the light harness endpoint (port 4005, localhost only)
#
# `server: false` here and switched on by `start_harness/0`, which only runs
# under `cms harness`. Every other way this application starts — the
# server, the SQLite CLI, a sprite, the test suite — compiles these modules and
# must not open the port.
#
# 4005 rather than 4004 so a laptop can run both harnesses side by side during
# the transition. A sprite sets `CMS_HARNESS_PORT=4004`, because there the light
# harness *is* the thing serving hooks and nothing else wants the port.
config :code_my_spec, CmsHarness.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4005],
  render_errors: [formats: [json: CmsHarness.Web.ErrorJSON], layout: false],
  # No LiveView, no signed session, no static cache manifest — none of them has
  # a caller. `secret_key_base` is still required by Phoenix.Endpoint, so it is
  # here rather than being a secret the operator has to supply.
  secret_key_base: String.duplicate("cms_harness_local_only", 4),
  server: false

# Configures the local developer web endpoint (port 4003, localhost only)
config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: true,
  secret_key_base: String.duplicate("local_dev_secret", 4),
  pubsub_server: CodeMySpec.PubSub,
  live_view: [signing_salt: "local_live_salt"],
  render_errors: [
    formats: [html: CodeMySpecLocalWeb.ErrorHTML, json: CodeMySpecLocalWeb.ErrorJSON],
    layout: false
  ]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  code_my_spec: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  code_my_spec_local: [
    args: ~w(js/local_app.js --bundle --target=es2022 --outdir=../priv/static/local/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  code_my_spec: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ],
  code_my_spec_local: [
    args: ~w(
      --input=assets/css/local_app.css
      --output=priv/static/local/assets/css/local_app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Default metadata kept across all environments. The prod_cli binary uses
# CodeMySpec.Logging.LogfmtFormatter (installed at runtime by
# CodeMySpec.Logging) and emits *all* metadata, so this list only governs
# the dev/test console formatter.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :reason,
    :total,
    :success,
    :errors,
    :duration_ms,
    :index,
    :changeset_errors,
    :changeset_changes,
    # GA Measurement Protocol structured-trace keys — exposed in the
    # dev/test formatter so the analytics tracing contract (story 812,
    # rule 5) is observable in those envs. Prod uses LogfmtFormatter
    # which emits all metadata regardless.
    :event,
    :user_id,
    :origin,
    :mp_status,
    :error,
    :body
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :paper_trail, repo: CodeMySpec.Repo, strict_mode: true

config :code_my_spec, ExOauth2Provider,
  repo: CodeMySpec.Repo,
  access_token: CodeMySpec.Oauth.AccessToken,
  application: CodeMySpec.Oauth.Application,
  access_grant: CodeMySpec.Oauth.AccessGrant,
  resource_owner: CodeMySpec.Users.User,
  use_refresh_token: true,
  # Disable global SSL enforcement - we validate localhost exceptions in Application changeset
  force_ssl_in_redirect_uri: false

config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

config :code_my_spec, CodeMySpec.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("w09FSTq2MKlGVsfejph/sQiw6j9PSrqmgpCccRNG33s="),
      iv_length: 12
    }
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
