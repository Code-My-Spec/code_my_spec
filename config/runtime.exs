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
if config_env() in [:dev_cli, :prod_cli] do
  config :code_my_spec,
    api_base_url: env!("API_BASE_URL", :string, "https://codemyspec.com"),
    oauth_base_url: env!("OAUTH_BASE_URL", :string, "https://codemyspec.com")

  # Resolve `~` on the user's machine. If we do this at compile time
  # (in {dev,prod}_cli.exs) it gets baked to the CI builder's $HOME
  # (`/Users/runner/...`) and every SQLite call fails with EACCES on end users.
  repo_config = Application.get_env(:code_my_spec, CodeMySpec.Repo, [])

  repo_config =
    repo_config
    |> Keyword.put(:database, Path.expand("~/.codemyspec/cli.db"))
    |> Keyword.put(:load_extensions, [SqliteVec.path()])

  config :code_my_spec, CodeMySpec.Repo, repo_config
end

# Web app mode
if config_env() not in [:dev_cli, :prod_cli] do
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
    adapter: Swoosh.Adapters.Mailgun,
    api_key: System.get_env("MAILGUN_API_KEY"),
    domain: System.get_env("MAILGUN_DOMAIN")
end
