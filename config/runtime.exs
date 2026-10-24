import Config
import Dotenvy

# Spex does not load test_helper.exs. Isolate restart hints before either
# test runner starts the harness, including each Spex shard.
if config_env() == :test do
  served_roots_dir =
    Path.join(System.tmp_dir!(), "cms_test_served_roots_#{System.pid()}")

  config :code_my_spec, :harness_served_roots_dir, served_roots_dir

  config :code_my_spec, CodeMySpec.Auth.HarnessOAuth,
    state_dir: Path.join(served_roots_dir, "oauth")

  System.at_exit(fn _ -> File.rm_rf(served_roots_dir) end)
end

# Load environment variables from .env files
env_dir_prefix = System.get_env("RELEASE_ROOT") || Path.expand("./envs")

source!([
  Path.absname(".env", env_dir_prefix),
  Path.absname("#{config_env()}.env", env_dir_prefix),
  System.get_env()
])

# Optional dev/test OAuth timings, in seconds. For a short QA cycle set
# CMS_DEVICE_CODE_TTL_SECONDS=12, CMS_DEVICE_CODE_INTERVAL_SECONDS=1,
# CMS_ACCESS_TOKEN_TTL_SECONDS=12, CMS_OAUTH_REFRESH_BEFORE_SECONDS=2,
# and CMS_OAUTH_CHECK_INTERVAL_SECONDS=1 on the server/harness being tested.
# Omitted variables preserve application configuration and production defaults.
if config_env() in [:dev, :test] do
  for {variable, module, key, minimum} <- [
        {"CMS_DEVICE_CODE_TTL_SECONDS", CodeMySpec.Oauth, :ttl_seconds, 0},
        {"CMS_DEVICE_CODE_INTERVAL_SECONDS", CodeMySpec.Oauth, :interval, 1},
        {"CMS_ACCESS_TOKEN_TTL_SECONDS", ExOauth2Provider, :access_token_expires_in, 1},
        {"CMS_OAUTH_REFRESH_BEFORE_SECONDS", CodeMySpec.Auth.HarnessOAuth,
         :refresh_before_seconds, 0},
        {"CMS_OAUTH_CHECK_INTERVAL_SECONDS", CmsHarness.Authorization, :check_interval_seconds, 1}
      ] do
    case System.get_env(variable) do
      nil ->
        :ok

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= minimum ->
            config :code_my_spec, module, [{key, seconds}]

          _ ->
            raise "#{variable} must be an integer >= #{minimum}"
        end
    end
  end
end

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

# The harness — `just harness` in dev and the installed `cms_harness`
# release. Everything that differs between those two is read here, from the
# environment, so one build serves both.
if config_env() == :harness do
  # Which server this harness reports to. `CMS_SERVER_URL` is also read
  # directly by `CmsHarness.Config.server_url/0`; it is resolved here too so
  # `:base_url` (the OAuth client, `cms migrate`) names the same server.
  server_url = System.get_env("CMS_SERVER_URL") || "https://codemyspec.com"

  config :code_my_spec,
    harness_default_server_url: server_url,
    base_url: server_url

  # The local CLI database `cms migrate` imports from. Resolved here so `~`
  # expands on the user's machine and not on the CI builder's.
  config :code_my_spec,
         CodeMySpec.Repo,
         Keyword.put(
           Application.get_env(:code_my_spec, CodeMySpec.Repo, []),
           :database,
           System.get_env("CMS_DB_PATH") || Path.join(CodeMySpec.Paths.user_state_dir(), "cli.db")
         )

  # Concurrent analyzer runs. Unset, `CmsHarness.AnalysisSlots.limit/0` takes a
  # fourth of the cores. `just harness` sets 1: that box runs one harness for
  # every worktree of this repo, and two full suites at once on it each took
  # longer than running them back to back.
  if slots = System.get_env("CMS_ANALYSIS_SLOTS") do
    config :code_my_spec, analysis_slots: String.to_integer(slots)
  end

  # The harness log handler takes `CMS_LOG_LEVEL`; the primary level has to
  # admit what it asks for, or a debug handler receives nothing.
  if (level = System.get_env("CMS_LOG_LEVEL")) in ~w(debug info warning error) do
    config :logger, level: String.to_existing_atom(level)
  end

  # `mix cms.content.publish` runs under this env (it needs the SQLite repo)
  # and signs S3 uploads and purges Cloudflare with these.
  config :ex_aws,
    access_key_id: env!("AWS_ACCESS_KEY_ID", :string, ""),
    secret_access_key: env!("AWS_SECRET_ACCESS_KEY", :string, ""),
    region: env!("AWS_REGION", :string, "us-east-1")

  config :code_my_spec, CodeMySpec.Content.CloudflareClient,
    api_token: env!("CLOUDFLARE_TOKEN", :string, ""),
    zone_id: env!("CLOUDFLARE_ZONE_ID", :string, "ba45c3c2010cb275de73f91f4f05edab")

  # Where the harness's hooks land. The plugin's `hooks.json` posts to a port
  # fixed at install time, so the port is what gets configured. Not applied in
  # test — `config/test.exs` picks its own port and `server: false`.
  if port = System.get_env("CMS_HARNESS_PORT") do
    config :code_my_spec, CmsHarness.Web.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end
end

# The preview address writes a CNAME per project onto our own zone, so it needs
# our own credential — not the visitor's, who has no reason to have connected
# Cloudflare at all. Outside the harness block above because this runs on the
# server: the harness env publishes content, the server serves previews.
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

# Web app mode
if config_env() != :harness do
  # Required everywhere but desktop, where OAuth and the deploy key are off.
  required = fn name ->
    if config_env() == :desktop, do: env!(name, :string, ""), else: env!(name)
  end

  config :code_my_spec,
    github_client_id: required.("GITHUB_CLIENT_ID"),
    github_client_secret: required.("GITHUB_CLIENT_SECRET"),
    google_client_id: required.("GOOGLE_CLIENT_ID"),
    google_client_secret: required.("GOOGLE_CLIENT_SECRET"),
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
    base_url:
      env!(
        "BASE_URL",
        :string,
        if(config_env() == :desktop,
          do: "http://127.0.0.1:47400",
          else: "https://dev.codemyspec.com"
        )
      ),
    deploy_key: required.("DEPLOY_KEY"),
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

# Embeddings rework step 2 (577de9bb): inference moves onto this server, so
# :dev and :prod both need a real backend and serving implementation now.
# Not :test — config/test.exs already points at TestBackend (ETS, no
# model), and loading the real 90MB ONNX file on every test boot for a
# backend nothing in that env calls would just be a slow no-op.
# Desktop's FirstBoot refuses a Postgres without pgvector, so it is always here.
if config_env() in [:dev, :prod] do
  config :code_my_spec,
    embeddings_backend: CodeMySpec.Embeddings.PgVectorBackend,
    embedding_serving: CodeMySpec.Embeddings.OrtexServing
end

if config_env() == :desktop do
  # One SQLite file beside the rest of the machine's CodeMySpec state.
  config :code_my_spec, CodeMySpec.Repo,
    database: CodeMySpec.Paths.desktop_database(),
    journal_mode: :wal,
    busy_timeout: 10_000,
    default_transaction_mode: :immediate,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Per install, created on first boot.
  config :code_my_spec, CodeMySpecWeb.Endpoint,
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") || CodeMySpecDesktop.Secret.read_or_create!()

  # For a machine where 47400 or 47403 is taken. The harness follows the app's
  # port, since base_url is the server it talks to.
  if port = System.get_env("PORT") do
    url = "http://127.0.0.1:#{port}"

    config :code_my_spec,
      base_url: url,
      api_base_url: url,
      oauth_base_url: url,
      harness_default_server_url: url

    config :code_my_spec, CodeMySpecWeb.Endpoint,
      url: [port: String.to_integer(port)],
      http: [port: String.to_integer(port)]
  end

  if port = System.get_env("CMS_HARNESS_PORT") do
    config :code_my_spec, CmsHarness.Web.Endpoint, http: [port: String.to_integer(port)]
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

  # BurstBox.FlyPeering's WireGuard peer (go-live checklist, application.ex).
  # Unset unless all five are present.
  burst_box_wg = [
    private_key: System.get_env("BURST_BOX_WG_PRIVATE_KEY"),
    address: System.get_env("BURST_BOX_WG_ADDRESS"),
    peer_public_key: System.get_env("BURST_BOX_WG_PEER_PUBLIC_KEY"),
    endpoint: System.get_env("BURST_BOX_WG_ENDPOINT"),
    allowed_ips: System.get_env("BURST_BOX_WG_ALLOWED_IPS")
  ]

  if Enum.all?(burst_box_wg, fn {_key, value} -> is_binary(value) and value != "" end) do
    config :code_my_spec, CodeMySpec.Provisioning.BurstBox.FlyPeering, peer: Map.new(burst_box_wg)
  end
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
#
# Both providers, because which one an environment has is a deployment fact
# rather than a product decision. Production ran for 25 days with neither: the
# key was never set there, every `shape/2` errored, and the guided intake — the
# front door, the one the landing page says needs no signup — was dead at its
# first turn the whole time.
config :req_llm,
  anthropic_api_key: env!("ANTHROPIC_API_KEY", :string, nil),
  openai_api_key: env!("OPENAI_API_KEY", :string, nil)

# And which model to spend. Configurable because the key an environment holds
# decides it: a deployment with only an OpenAI key cannot run the Anthropic
# default, and pinning the model in code makes the two settings able to
# disagree — which reads, from the front, exactly like the missing key did.
# Two models sit behind guided intake — the shaper asks the questions, the
# planner writes the plan — and only the shaper's was configurable. The planner
# kept an Anthropic default on a deployment holding only an OpenAI key, could
# not reach a model at all, and fell back to its offline heuristic without
# saying so. Both follow the environment now, and `PLANNER_MODEL` falls back to
# `INTAKE_MODEL` so the ordinary case is one setting rather than two that can
# drift apart.
intake_model = env!("INTAKE_MODEL", :string, "anthropic:claude-sonnet-5")

# Shaping runs through `Shaper.Llm` unless this says otherwise. The phase port
# (`CodeMySpec.Intake.Phases.Shape`, run by `CodeMySpec.Agents.Phase`) is proven
# against the same recorded calls — `ShaperPhaseAlloyTest` replays the cassettes
# `ShaperLlmAlloyTest` recorded, and `ShapeTest` asserts the prompt is byte-
# identical to what is on disk — but equivalence under two recordings is not the
# same as equivalence in front of visitors, so the switch is deliberate.
#
#     INTAKE_SHAPER=phase mix phx.server
#
# Anything else, or unset, is the implementation that has been serving.
intake_shaper =
  case env!("INTAKE_SHAPER", :string, nil) do
    "phase" -> CodeMySpec.Intake.Shaper.Phase
    _ -> CodeMySpec.Intake.Shaper.Llm
  end

config :code_my_spec, CodeMySpec.Intake,
  model: intake_model,
  planner_model: env!("PLANNER_MODEL", :string, nil) || intake_model

# A separate call, and skipped in test, because `config/2` merges by key: setting
# `shaper` in the block above overwrote `config/test.exs`'s `Shaper.Scripted` and
# the whole suite started resolving to `Shaper.Llm`. Confirmed by reading the
# resolved config back in `MIX_ENV=test` rather than inferred — the suite still
# passed while it was wrong, which is exactly why it needed looking at.
unless config_env() == :test do
  config :code_my_spec, CodeMySpec.Intake, shaper: intake_shaper
end

# Web search and fetch for agents. Fetching needs nothing; searching needs a key
# for one of the three providers, and `Research.Search` uses whichever is set —
# so an environment with no key still starts, and `web_search` refuses there
# with a message naming these variables rather than failing at boot.
#
# Skipped in test, where this file runs *after* `config/test.exs` and a whole
# `config/2` call replaces rather than merges: setting three nil keys here
# would silently unset the fake key and the `Req.Test` plug, and every search
# test would exercise the "no provider configured" refusal instead of the thing
# it means to test (`reference_runtime_exs_overrides_test_config`).
unless config_env() == :test do
  config :code_my_spec, CodeMySpec.Research,
    tavily_api_key: env!("TAVILY_API_KEY", :string, nil),
    brave_api_key: env!("BRAVE_API_KEY", :string, nil),
    serper_api_key: env!("SERPER_API_KEY", :string, nil)
end

# Stripe. Blank when unset rather than absent, so an unconfigured environment
# degrades to a normal error the billing page can show instead of crashing
# inside Req's bearer-auth step.
#
# Guarded the same way Research is above: unconditional here clobbered
# config/test.exs's fixture values with these empty-string fallbacks at
# boot, so every spex fell back to the dynamic per-test `Application.put_env`
# in `stub_stripe_by_default/0` to win the race back -- which only worked
# because it ran later (per-test setup, after boot), and which is exactly
# the global-mutable-state pattern that isn't safe under concurrent spex
# (`reference_runtime_exs_overrides_test_config`).
unless config_env() == :test do
  config :code_my_spec, CodeMySpec.Billing.StripeClient,
    secret_key: env!("STRIPE_SECRET_KEY", :string, "")

  config :code_my_spec, CodeMySpec.Billing,
    publishable_key: env!("STRIPE_PUBLISHABLE_KEY", :string, ""),
    webhook_secret: env!("STRIPE_WEBHOOK_SECRET", :string, ""),
    light_price_id: env!("STRIPE_LIGHT_PRICE_ID", :string, ""),
    pro_price_id: env!("STRIPE_PRO_PRICE_ID", :string, "")
end

# Our own credential for a visitor's first turns before they connect a
# provider (story 875) — `Credential.platform_credential/1` reads this and is
# off by default (blank string), which the module's own moduledoc calls
# deliberate: spending real money on someone who may never come back needs a
# human to switch it on, bounded by `:platform_turn_cap`.
config :code_my_spec, CodeMySpec.Agents.Credential,
  platform_api_key: env!("PLATFORM_API_KEY", :string, "")

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

# Microsoft Clarity — prod only (see envs/prod.env comment). Unset in every
# other env, so the script simply doesn't render there.
config :code_my_spec, :clarity_project_id, env!("CLARITY_PROJECT_ID", :string, nil)
