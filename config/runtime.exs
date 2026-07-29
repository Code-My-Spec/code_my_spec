import Config
import Dotenvy

# Load environment variables from .env files
env_dir_prefix = System.get_env("RELEASE_ROOT") || Path.expand("./envs")

source!([
  Path.absname(".env", env_dir_prefix),
  Path.absname("#{config_env()}.env", env_dir_prefix),
  System.get_env()
])

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/code_my_spec start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :code_my_spec, CodeMySpecWeb.Endpoint, server: true
end

# Cloudflare Tunnel — merge secret from env var (dev only)
tunnel_config = Application.get_env(:code_my_spec, :cloudflare_tunnel, [])

if tunnel_config[:mode] == :named do
  config :code_my_spec, :cloudflare_tunnel,
    Keyword.put(tunnel_config, :tunnel_secret, env!("CLOUDFLARE_TUNNEL_SECRET", :string, ""))
end

# CLI mode — minimal runtime config
if config_env() in [:dev_cli, :prod_cli, :cli_demo] do
  # api_base_url / oauth_base_url / base_url are now set per-env in
  # dev_cli.exs and prod_cli.exs at compile time so the shipped binary
  # is statically wired to prod and the in-repo build is wired to dev.

  # Resolve `~` on the user's machine. If we do this at compile time
  # (in {dev,prod}_cli.exs) it gets baked to the CI builder's $HOME
  # (`/Users/runner/...`) and every SQLite call fails with EACCES on end users.
  #
  # Dev_cli uses a separate file so an in-repo `mix run` can't trample
  # the schema the published `cms` binary is using.
  cli_db_filename =
    case config_env() do
      :prod_cli -> "cli.db"
      :dev_cli -> "cli_dev.db"
      :cli_demo -> "cli_demo.db"
    end

  repo_config = Application.get_env(:code_my_spec, CodeMySpec.Repo, [])

  repo_config =
    repo_config
    |> Keyword.put(
      :database,
      System.get_env("CMS_DB_PATH") || Path.expand("~/.codemyspec/#{cli_db_filename}")
    )
    |> Keyword.put(:load_extensions, [SqliteVec.path()])

  config :code_my_spec, CodeMySpec.Repo, repo_config

  # Demo/sandbox overrides — env-var gated, no effect on a normal dev_cli boot.
  # CMS_PORT runs the local web on another port so a replay instance can
  # coexist with the real dev_cli app on :4004.
  if demo_port = System.get_env("CMS_PORT") do
    config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(demo_port)]
  end

  # CMS_API_BASE_URL repoints sync/auth at a local demo server instead of
  # dev.codemyspec.com, so a replay never touches real dev/prod data.
  if api = System.get_env("CMS_API_BASE_URL") do
    config :code_my_spec, api_base_url: api, oauth_base_url: api, base_url: api
  end

  # Allow seed scripts to run while the local app already occupies port 4003.
  # Set NO_SERVER=true to skip the HTTP listener (Repo is still available).
  # Example: NO_SERVER=true MIX_ENV=dev_cli mix run priv/repo/cli_qa_seeds.exs
  if System.get_env("NO_SERVER") do
    config :code_my_spec, CodeMySpecLocalWeb.Endpoint, server: false
  end

  # Content publishing (story 712): the local CLI is the publisher — it signs
  # S3 uploads with the user's own AWS creds and purges Cloudflare directly.
  # These reach dev_cli via envs/.env (loaded for every env at line 8), so wire
  # them here too (the web-env block above doesn't run for the cli server).
  config :ex_aws,
    access_key_id: env!("AWS_ACCESS_KEY_ID", :string, ""),
    secret_access_key: env!("AWS_SECRET_ACCESS_KEY", :string, ""),
    region: env!("AWS_REGION", :string, "us-east-1")

  config :code_my_spec, CodeMySpec.Content.CloudflareClient,
    api_token: env!("CLOUDFLARE_TOKEN", :string, ""),
    zone_id: env!("CLOUDFLARE_ZONE_ID", :string, "ba45c3c2010cb275de73f91f4f05edab")
end

# Sprite mode — the harness on centralized data.
#
# Deliberately NOT part of the CLI block above: that block's whole job is to
# resolve a per-machine SQLite path, and a sprite has no local database at all.
# Connection details come from the environment so one image can be pointed at
# a different database without a rebuild — which is what makes a sprite
# disposable.
if config_env() == :dev_sprite do
  repo_config =
    case System.get_env("CMS_DATABASE_URL") do
      nil ->
        [
          database: System.get_env("CMS_DB_NAME") || "code_my_spec_sprite_dev",
          hostname: System.get_env("CMS_DB_HOST") || "localhost",
          port: String.to_integer(System.get_env("CMS_DB_PORT") || "5432"),
          username: System.get_env("CMS_DB_USER") || System.get_env("USER") || "postgres",
          password: System.get_env("CMS_DB_PASSWORD") || ""
        ]

      url ->
        [url: url]
    end

  config :code_my_spec,
         CodeMySpec.Repo,
         Keyword.merge(
           Application.get_env(:code_my_spec, CodeMySpec.Repo, []),
           repo_config
         )

  # Same escape hatches the CLI block provides, since a sprite needs them for
  # the same reasons: run a script without binding a port, or coexist with
  # another harness on the machine.
  if port = System.get_env("CMS_PORT") do
    config :code_my_spec, CodeMySpecLocalWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end

  if System.get_env("NO_SERVER") do
    config :code_my_spec, CodeMySpecLocalWeb.Endpoint, server: false
  end

  # Which project this sprite is for. Scopes anything that would otherwise
  # read "all linked projects" out of a now-shared table — see
  # ProjectSync.FileWatcherServer.watchable_projects/0.
  if project_id = System.get_env("CMS_PROJECT_ID") do
    config :code_my_spec, project_id: project_id
  end
end

# Web app mode
if config_env() not in [:dev_cli, :prod_cli, :cli_demo, :dev_sprite] do
  config :code_my_spec,
    github_client_id: env!("GITHUB_CLIENT_ID"),
    github_client_secret: env!("GITHUB_CLIENT_SECRET"),
    google_client_id: env!("GOOGLE_CLIENT_ID"),
    google_client_secret: env!("GOOGLE_CLIENT_SECRET"),
    base_url: env!("BASE_URL", :string, "https://dev.codemyspec.com"),
    deploy_key: env!("DEPLOY_KEY"),
    indexnow_key: env!("BING_SITEMASTER_INDEXNOW_KEY", :string, nil)

  # S3 uploads (issue screenshots)
  config :code_my_spec, s3_bucket: env!("S3_BUCKET", :string, "codemyspec-uploads")

  # Google Ads developer token — server-side only, never exposed to the agent.
  # Optional: when unset the Ads tools return a "developer token not configured"
  # error rather than crashing boot.
  config :code_my_spec, CodeMySpec.Google.Ads,
    developer_token: env!("GOOGLE_ADS_DEVELOPER_TOKEN", :string, "")

  # Static images host (e.g. "https://images.codemyspec.com" for R2). Empty
  # falls back to app-served /images/... so local dev keeps working.
  config :code_my_spec, images_host: env!("IMAGES_HOST", :string, "")

  config :ex_aws,
    access_key_id: env!("AWS_ACCESS_KEY_ID", :string, ""),
    secret_access_key: env!("AWS_SECRET_ACCESS_KEY", :string, ""),
    region: env!("AWS_REGION", :string, "us-east-1")

  # Web Push VAPID configuration
  vapid_public_key = env!("VAPID_PUBLIC_KEY", :string, nil)
  vapid_private_key = env!("VAPID_PRIVATE_KEY", :string, nil)
  vapid_subject = env!("VAPID_SUBJECT", :string, "mailto:support@codemyspec.com")

  if vapid_public_key && vapid_private_key do
    config :web_push_elixir,
      vapid_public_key: vapid_public_key,
      vapid_private_key: vapid_private_key,
      vapid_subject: vapid_subject
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :code_my_spec, CodeMySpec.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "8080")

  config :code_my_spec, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :code_my_spec, CodeMySpecWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: [
      "https://#{host}",
      "https://www.#{host}"
    ],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :code_my_spec, CodeMySpec.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: env!("RESEND_API_KEY", :string, "")
end

# Resend Domains API (in-app sending-domain onboarding). Needed in ALL envs,
# not just prod: even in dev the domain register/verify calls hit the real
# provider (outbound mail still uses the per-env Mailer adapter). Sourced from
# envs/<env>.env via Dotenvy above; empty string → client returns
# {:error, :resend_not_configured}.
config :code_my_spec, CodeMySpec.Mail.ResendClient,
  api_key: env!("RESEND_API_KEY", :string, "")

# Svix signing secret for the inbound Resend webhook (`whsec_…`). When unset
# (e.g. tests, dev without inbound) signature verification is skipped.
config :code_my_spec, :resend_webhook_secret, env!("RESEND_WEBHOOK_SECRET", :string, "")

# GA4 Measurement Protocol — server-side delivery of activation events.
# Applies to dev + prod (test overrides http_adapter to a no-op so unit
# tests can't accidentally POST to real GA). measurement_id + api_secret
# come from envs/<env>.env (gitignored) via Dotenvy above.
# If GA4_MP_API_SECRET is unset the handler logs "skipped" and no-ops —
# signups still work without it.
#
# In test: use GA4_MEASUREMENT_ID from env if set, otherwise fall back to
# a stub value so the gtag snippet renders in test HTML without hitting GA.
ga_measurement_id =
  env!("GA4_MEASUREMENT_ID", :string, nil) ||
    if config_env() == :test, do: "G-TEST000000"

config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics,
  measurement_id: ga_measurement_id,
  api_secret: env!("GA4_MP_API_SECRET", :string, nil)
