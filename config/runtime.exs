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
  config :code_my_spec,
         :cloudflare_tunnel,
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

# The preview address writes a CNAME per project onto our own zone, so it needs
# our own credential — not the visitor's, who has no reason to have connected
# Cloudflare at all. Outside the CLI guard above because this runs on the
# server: the CLI publishes content, the server serves previews.
#
# Same account as the content client, different zone. Previews live on
# astralbi.com so a wildcard does not sit across the production domain, and so a
# malformed hostname in a generated tunnel config cannot take
# dev.codemyspec.com down with it — which is exactly what happened here once.
config :code_my_spec, CodeMySpec.Workspaces.PreviewAddress,
  token: env!("CLOUDFLARE_TOKEN", :string, ""),
  # The zone previews live in, and it must agree with `base_domain` wherever
  # that is set. This file runs *after* `config/dev.exs`, so a zone chosen there
  # is overwritten by this line — which is how a hostname on one domain got
  # written into another zone. Cloudflare does not reject that: a name outside
  # the zone is treated as relative and the zone is appended, producing
  # `preview-<id>.codemyspec.com.astralbi.com` and a success response.
  zone_id: env!("CLOUDFLARE_PREVIEW_ZONE_ID", :string, "ba45c3c2010cb275de73f91f4f05edab")

# The tunnel half of the same story, for a preview whose app we do not host and
# cannot dial. Same zone as the address above, because the record still has to
# be ours — see `PreviewTunnel`'s moduledoc for why an app-chosen hostname
# breaks the proxy, the CSP and Safari's cookie handling at once.
#
# A separate token, and not for tidiness. Creating a tunnel is an *account*
# operation (`POST /accounts/{id}/cfd_tunnel`), and `CLOUDFLARE_TOKEN` is
# zone-scoped: it writes DNS on the preview zone perfectly well and returns an
# empty list from `GET /accounts`, so a tunnel create against it fails with a
# permissions error that reads like a bad account id. Needs `Cloudflare
# Tunnel:Edit` at account scope.
#
# Unset, `ensure/1` returns `:no_cloudflare_account_id` rather than half-
# provisioning: no tunnel is created, no record is written, and the panel goes
# on saying no preview is running, which is true.
# Not in test. This file runs for every environment and runs *after*
# `config/test.exs`, so an unguarded block here overwrites the pinned stub and
# the placeholder credentials with empty strings — the suite then fails on a
# missing account id rather than on anything it is testing.
unless config_env() == :test do
  # No `zone_id` here on purpose. `PreviewTunnel` falls back to
  # `PreviewAddress`'s, so the zone previews live in is decided in one place —
  # and it has to be, because the zone is what makes a preview same-site with
  # the app framing it. Two settings could disagree, and the symptom of
  # disagreeing is a framed app that cannot hold a session.
  config :code_my_spec, CodeMySpec.Workspaces.PreviewTunnel,
    token: env!("CLOUDFLARE_TUNNEL_TOKEN", :string, env!("CLOUDFLARE_TOKEN", :string, "")),
    account_id: env!("CLOUDFLARE_ACCOUNT_ID", :string, "")
end

# Sprite mode — the harness on centralized data.
#
# Deliberately NOT part of the CLI block above: that block's whole job is to
# resolve a per-machine SQLite path, and a sprite has no local database at all.
# Connection details come from the environment so one image can be pointed at
# a different database without a rebuild — which is what makes a sprite
# disposable.
# `CMS_HARNESS_PORT` decides where the light harness's hooks land.
#
# The plugin's `hooks.json` posts to a URL fixed at install time, so the port
# is the thing to configure rather than the plugin: editing hooks.json would
# repoint *every* Claude Code session on the machine, including ones working
# against the heavy local application.
#
# Default 4005 (config.exs) so a laptop can run both. A sprite sets 4004,
# because there the light harness *is* what serves hooks.
#
# Hoisted out of the `[:dev_cli, :prod_cli, :cli_demo]` block above, which is
# about the CLI's SQLite database and had no business owning this. `:dev_sprite`
# was missing from that list, so a sprite could not set its harness port at all
# — it silently kept config.exs's 4005 while `sprite.sh` logged "Starting the
# light harness on 4003". Measured in a container: `CMS_HARNESS_PORT=4003` and
# the endpoint came up on 4005 anyway. Nothing noticed because a sprite runs the
# *standalone* cms_harness release today, which reads its own config (bddb1ac1).
#
# Deliberately not adding :dev_sprite to that block instead: it maps each env to
# a `.db` filename in a `case` with no :dev_sprite clause, so a sprite would
# have crashed on a CaseClauseError to gain a port it does not need a database
# for.
#
# Still not applied in test — `config/test.exs` picks a port of its own and
# `server: false`, and runtime config is evaluated last and would undo both.
if config_env() in [:dev_cli, :prod_cli, :cli_demo, :dev_sprite] do
  if port = System.get_env("CMS_HARNESS_PORT") do
    config :code_my_spec, CmsHarness.Web.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end
end

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

  # Which project this sprite is for, and where it cloned the working copy.
  #
  # Both are runtime facts the launcher knows and the shared project row
  # cannot: that row is one row for every checkout, so it can neither identify
  # which project *this* container serves nor describe this container's disk.
  # Scopes file watching (ProjectSync.FileWatcherServer.watchable_projects/0)
  # and scope resolution (Projects.resolve_local_project/1).
  if project_id = System.get_env("CMS_PROJECT_ID") do
    config :code_my_spec, project_id: project_id
  end

  if working_dir = System.get_env("CMS_MCP_WORKING_DIR") do
    config :code_my_spec, mcp_working_dir: working_dir
  end

  # The project's deploy key — the sprite's only credential for reaching the
  # server, and it needs one for exactly one thing: raising a question to a
  # human when a manual requirement needs a decision. Everything else it does
  # against the database directly. See Notifications.QuestionClient.
  if deploy_key = System.get_env("CMS_DEPLOY_KEY") do
    config :code_my_spec, deploy_key: deploy_key
  end

  # Point the sprite at a different server than the compile-time default.
  # dev_sprite.exs wires api/oauth/base to dev.codemyspec.com; this is how a
  # sprite is aimed at a server running locally, which is the only way to
  # exercise a server-side change before it is deployed.
  if api = System.get_env("CMS_API_BASE_URL") do
    config :code_my_spec, api_base_url: api, oauth_base_url: api, base_url: api
  end
end

# Web app mode
if config_env() not in [:dev_cli, :prod_cli, :cli_demo, :dev_sprite] do
  config :code_my_spec,
    github_client_id: env!("GITHUB_CLIENT_ID"),
    github_client_secret: env!("GITHUB_CLIENT_SECRET"),
    google_client_id: env!("GOOGLE_CLIENT_ID"),
    google_client_secret: env!("GOOGLE_CLIENT_SECRET"),
    cloudflare_client_id: env!("CLOUDFLARE_CLIENT_ID", :string, ""),
    cloudflare_client_secret: env!("CLOUDFLARE_CLIENT_SECRET", :string, ""),
    resend_client_id: env!("RESEND_CLIENT_ID", :string, ""),
    resend_client_secret: env!("RESEND_CLIENT_SECRET", :string, ""),
    # No `openai_client_id` here on purpose. OpenAI's is a public-client flow —
    # PKCE and a client id, no secret — and the client id is *theirs*: their
    # Codex CLI client, because OpenAI documents no third-party registration for
    # subscription sign-in. `Providers.OpenAI.client_id/0` hardcodes it and
    # explains why.
    #
    # This line used to read `env!("OPENAI_CLIENT_ID", :string, "")`, and
    # `Application.get_env/3` only falls back to its own default when the key is
    # absent — so the empty string won, on every environment, and nobody could
    # connect a ChatGPT subscription anywhere. The device code request succeeds
    # with an empty client id, so the user completed the flow, was told it
    # worked, and only the exchange failed. An env var offering to configure
    # something that cannot be configured is the whole trap.
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
#
# Except test, which sets its own in `config/test.exs`. `runtime.exs` is
# evaluated after the per-env file, so without this guard the line below
# replaced the test key with `""` and every stubbed call short-circuited to
# `:resend_not_configured` — a test that had configured the client correctly
# and was told it had not. That is why the mail spex install this key with
# `Application.put_env/3` at runtime instead of configuring it: the config
# they wrote was being overwritten before they ran.
unless config_env() == :test do
  config :code_my_spec, CodeMySpec.Mail.ResendClient, api_key: env!("RESEND_API_KEY", :string, "")
end

# Guided intake writes its plan with a model, so req_llm needs a provider key.
# ReqLLM resolves keys from `config :req_llm, <provider>_api_key`. Left nil when
# unset — the planner then fails with :plan_unavailable and the visitor is told,
# rather than the key's absence surfacing as a crash mid-flow.
config :req_llm, anthropic_api_key: env!("ANTHROPIC_API_KEY", :string, nil)

# Stripe. Blank when unset rather than absent, so an unconfigured environment
# degrades to a normal error the billing page can show instead of crashing
# inside Req's bearer-auth step.
config :code_my_spec, CodeMySpec.Billing.StripeClient,
  secret_key: env!("STRIPE_SECRET_KEY", :string, "")

config :code_my_spec, CodeMySpec.Billing,
  publishable_key: env!("STRIPE_PUBLISHABLE_KEY", :string, ""),
  webhook_secret: env!("STRIPE_WEBHOOK_SECRET", :string, ""),
  light_price_id: env!("STRIPE_LIGHT_PRICE_ID", :string, ""),
  pro_price_id: env!("STRIPE_PRO_PRICE_ID", :string, "")

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

# The api_secret is withheld in test, which is what actually stops delivery:
# `deliver/2` checks for `measurement_id` and `api_secret` and logs "skipped"
# when either is missing, so the measurement id can stay and the gtag snippet
# still renders in test HTML.
#
# The comment above claimed test "overrides http_adapter to a no-op so unit
# tests can't accidentally POST to real GA". There was no such override —
# `http_adapter` read `nil` in test — and `envs/test.env` supplies a real
# measurement id and api_secret, not the `G-TEST000000` fallback. So the suite
# was delivering: 2,407 events in one run — `sign_up`, `intake_*`,
# `workspace_*` — as real POSTs to the live property, from every worktree, on
# every run.
#
# `config/test.exs` also pins `{Req.Test, HTTPAdapter}` now, so a call that
# gets past this raises instead of reaching Google. Two independent guards,
# because the one that was documented did not exist.
ga_api_secret =
  if config_env() == :test, do: nil, else: env!("GA4_MP_API_SECRET", :string, nil)

config :code_my_spec, CodeMySpec.Analytics.GoogleAnalytics,
  measurement_id: ga_measurement_id,
  api_secret: ga_api_secret
