defmodule CodeMySpecWeb.Router do
  use CodeMySpecWeb, :router

  import CodeMySpecWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodeMySpecWeb.Layouts, :root}
    plug CodeMySpecWeb.Plugs.CurrentPath
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "strict-transport-security" => "max-age=63072000; includeSubDomains; preload",
      "permissions-policy" => "camera=(), microphone=(), geolocation=()",
      "x-frame-options" => "SAMEORIGIN"
    }

    plug :fetch_current_scope_for_user
    plug CodeMySpecWeb.Plugs.GaClientId
    plug CodeMySpecWeb.Plugs.CSP
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mcp do
    plug :accepts, ["json", "sse"]
  end

  pipeline :mcp_protected do
    plug :accepts, ["json", "sse"]
    plug :require_oauth_token
    plug CodeMySpecWeb.Plugs.ProjectScopeOverride
    # After the scope, because the agent is resolved within the project this
    # request is already scoped to — see `AgentScope`.
    plug CodeMySpecWeb.Plugs.AgentScope
  end

  # Guided intake. Its own pipeline: the anonymous plan token must be minted
  # before the LiveView mounts, which cannot write the session.
  pipeline :intake do
    plug CodeMySpecWeb.Plugs.IntakeSession
  end

  # Unauthenticated, no session: `just reload` asks it after a promote.
  scope "/", CodeMySpecWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", CodeMySpecWeb do
    pipe_through [:browser, :intake]

    live_session :intake,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/build", IntakeLive.Plan, :plan
      live "/build/procedural", IntakeLive.Procedural, :procedural
    end

    # Email from the sign-up card — a plain form post, not `phx-submit`,
    # since establishing the session cookie is a controller's job.
    post "/build/sign-up", IntakeSignupController, :create

    # Wipes a test run back to the root — a plain form post, since clearing
    # the session is a controller's job same as signing up is.
    post "/build/reset", IntakeResetController, :create

    live_session :intake_workspace,
      on_mount: [
        {CodeMySpecWeb.UserAuth, :mount_current_scope},
        {CodeMySpecWeb.UserAuth, :require_authenticated}
      ] do
      live "/build/workspace", IntakeLive.Workspace, :workspace
      live "/build/preview", PreviewLive.Show, :show
    end
  end

  scope "/", CodeMySpecWeb do
    # The home page starts intake against the same anonymous token /build reads,
    # so one visitor is one plan.
    pipe_through [:browser, :intake]

    get "/", PageController, :home
    post "/build", PageController, :start_build
    get "/product", PageController, :product
    get "/agents", PageController, :agents
    get "/design-system", PageController, :design_system
    get "/behavior", PageController, :behavior
    get "/vibe-coding-rebuild", PageController, :vibe_coding_rebuild
    get "/developers", PageController, :developers
    get "/install", PageController, :install
    get "/pricing", PageController, :pricing
    get "/products/code-my-spec", PageController, :code_my_spec
    get "/products/market-my-spec", PageController, :market_my_spec_redirect
    get "/sitemap.xml", SitemapController, :index
    get "/llms.txt", LlmsTxtController, :index
    get "/llms-full.txt", LlmsTxtController, :full

    # Content index pages (dead views)
    get "/blog/feed.xml", FeedController, :blog
    get "/blog", ContentController, :blog_index
    get "/documentation", ContentController, :documentation_index
    get "/pages", ContentController, :pages_index

    # Content routes that remain as LiveViews (have interactivity).
    # NOTE: must come BEFORE the `/blog/:slug` dead-view route so the LiveView
    # wins the match.
    live_session :public_content,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/methodology", ContentLive.Pages.Methodology, :methodology
      live "/case-studies", ContentLive.Pages.CaseStudiesIndex, :case_studies
      live "/case-studies/metric-flow", ContentLive.Pages.MetricFlow, :metric_flow
      live "/case-studies/market-my-spec", ContentLive.Pages.MarketMySpec, :market_my_spec
      live "/case-studies/cleaner-crm", ContentLive.Pages.CleanerCrm, :cleaner_crm
      live "/case-studies/keel", ContentLive.Pages.Keel, :keel
      live "/case-studies/legwork", ContentLive.Pages.Legwork, :legwork
      live "/case-studies/ear-witness", ContentLive.Pages.EarWitness, :ear_witness
      live "/case-studies/broken-oaths", ContentLive.Pages.BrokenOaths, :broken_oaths

      live "/blog/agentic-marketing-with-mcp",
           ContentLive.Pages.AgenticMarketingWithMcp,
           :agentic_marketing_with_mcp

      live "/author/john-davenport", AuthorLive, :author
    end

    # Tag-filtered index pages, declared before the `:slug` routes.
    get "/blog/tag/:tag", ContentController, :blog_tag
    get "/pages/tag/:tag", ContentController, :pages_tag
    get "/landing/tag/:tag", ContentController, :landing_tag
    get "/documentation/tag/:tag", ContentController, :documentation_tag

    # Content detail pages (dead views — static content, no WebSocket)
    get "/blog/:slug", ContentController, :blog
    get "/pages/:slug", ContentController, :page
    get "/landing/:slug", ContentController, :landing
    get "/documentation/:slug", ContentController, :documentation
  end

  # Protected content routes (dead views)
  scope "/private", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/blog/:slug", ContentController, :private_blog
    get "/pages/:slug", ContentController, :private_page
    get "/landing/:slug", ContentController, :private_landing
    get "/documentation/:slug", ContentController, :private_documentation
  end

  # OAuth2 routes
  scope "/oauth", CodeMySpecWeb do
    pipe_through :browser

    get "/authorize", OAuthController, :authorize
    post "/authorize", OAuthController, :create
    delete "/authorize", OAuthController, :delete

    # Device authorization grant (RFC 8628) -- the human half. A harness
    # prints the verification URL and the code; this is where whoever reads
    # it off the screen decides.
    get "/device", DeviceAuthorizationController, :new
    post "/device", DeviceAuthorizationController, :show
    post "/device/decide", DeviceAuthorizationController, :decide
  end

  # OAuth2 API endpoints (no CSRF protection)
  scope "/oauth", CodeMySpecWeb do
    pipe_through :api

    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
    post "/register", OAuthController, :register

    # Device authorization grant (RFC 8628) -- the machine half. The
    # harness's own call, naming the client it registered and getting back
    # the code pair to show a person and to poll /oauth/token with.
    post "/device/code", DeviceAuthorizationController, :create
  end

  # MCP clients fall back to /register when they can't fetch authorization server metadata
  scope "/", CodeMySpecWeb do
    pipe_through :api

    post "/register", OAuthController, :register
  end

  # MCP OAuth discovery endpoints
  scope "/.well-known", CodeMySpecWeb do
    pipe_through :api

    get "/oauth-protected-resource", OAuthController, :protected_resource_metadata
    get "/oauth-protected-resource/*path", OAuthController, :protected_resource_metadata
    get "/oauth-authorization-server", OAuthController, :authorization_server_metadata
    get "/oauth-authorization-server/*path", OAuthController, :authorization_server_metadata
  end

  # MCP Server routes
  scope "/mcp" do
    pipe_through :mcp_protected

    # The harness tools. `require_oauth_token` identifies the user and
    # `ProjectScopeOverride` picks the project from `X-Project-ID`; Anubis copies
    # `conn.assigns` into the request context. A request without a project is
    # refused. File-touching tools also need a working copy: `X-Harness-Id`, or an
    # `X-Agent-Id`'s own copy (`AgentScope`); otherwise `:no_environment`.
    #
    # Five-minute timeout: real provisioning steps (:deploy, ~3 minutes) outlast
    # the 30s default, which returned false errors for calls that were working.
    forward "/harness", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.LocalServer,
      request_timeout: :timer.minutes(5)

    forward "/components", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.ComponentsServer

    forward "/gsc", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.GscServer

    forward "/ga4", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.Ga4Server

    forward "/google-ads", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.GoogleAdsServer
  end

  # API routes
  scope "/api", CodeMySpecWeb do
    pipe_through [:api, :require_oauth_token, CodeMySpecWeb.Plugs.ProjectScopeOverride]

    get "/me", UserController, :me
    get "/projects", ProjectController, :index

    resources "/issues", IssuesController, only: [:index, :show, :create, :update]

    # One project's authored graph, one request, one transaction.
    post "/migrations", MigrationsController, :create

    # Blocks until the connected project's provisioning RunLock is free — see
    # ProvisioningController's moduledoc for why this is plain HTTP rather
    # than an MCP tool or a code-mode script.
    post "/provisioning/wait", ProvisioningController, :wait

    post "/uploads/presign", UploadController, :create

    post "/notifications/push", NotificationController, :push

    post "/permissions/request", PermissionController, :create
    post "/permissions/:id/respond", PermissionController, :respond
    get "/permissions/:id/status", PermissionController, :status
  end

  # Questions are the one API a sprite needs, and a sprite has no user to run
  # an OAuth flow as — see `Plugs.DeployKeyOrOAuth`. The plug still accepts
  # OAuth, so the desktop CLI reaches these unchanged; only the accepted
  # credential widened, and only here.
  scope "/api", CodeMySpecWeb do
    pipe_through [:api, CodeMySpecWeb.Plugs.DeployKeyOrOAuth]

    # A sprite trades its deploy key for a real OAuth token here, then uses that
    # everywhere else. Keeps the deploy key narrow — see SpriteTokenController.
    post "/sprite/token", SpriteTokenController, :create

    # Where a harness is. The harness has an id and needs a directory; this is
    # the side that knows, and keeping it here is what lets the harness hold no
    # local record of working copies at all.
    get "/harnesses/:id", HarnessLookupController, :show
    post "/harnesses", HarnessLookupController, :create

    # Where this copy's preview answers, provisioned on first ask. Here rather
    # than in onboarding because making a tunnel needs our Cloudflare
    # credential, and onboarding ships in `client_utils` so a generated
    # application can run it — see the action's doc.
    post "/harnesses/:id/preview", HarnessLookupController, :preview

    # A machine announcing itself, which happens before it has any working copy
    # — so it cannot ride `harness_project:<project_id>`, a channel per
    # checkout. Here rather than there for the same reason the lookup above is.
    post "/devices", DeviceController, :create

    # A dev box trades its own token for a short-lived access token (story 1131).
    post "/devices/token", DeviceTokenController, :create

    # The cached requirement graph — the local app's
    # `/api/projects/:project_name/requirements/graph`, for a caller holding a
    # deploy key or an OAuth token instead of a seat on the machine.
    get "/projects/:project_id/requirements/graph", RequirementsGraphController, :show
  end

  # VAPID public key (no auth needed — it's a public key)
  scope "/api/browser", CodeMySpecWeb do
    pipe_through :api

    get "/push-subscriptions/vapid-key", PushSubscriptionController, :vapid_key
  end

  # Browser push subscription management (browser session auth)
  scope "/api/browser", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/push-subscriptions", PushSubscriptionController, :create
    delete "/push-subscriptions", PushSubscriptionController, :delete
  end

  # Inbound mail webhook (Resend Receiving API). Public; signature
  # verification deferred for v1 (see priv/knowledge/resend/receiving.md).
  scope "/webhooks", CodeMySpecWeb do
    pipe_through :api

    post "/resend", ResendWebhookController, :inbound

    # Must live under /webhooks/ — CacheBodyReader only keeps the raw bytes for
    # this prefix, and the HMAC has to be computed over exactly what Stripe sent.
    post "/stripe", StripeWebhookController, :create
  end

  # The one endpoint a deployed app's refresh secret opens; everything else takes
  # the short-lived token this returns.
  scope "/api", CodeMySpecWeb do
    pipe_through :api

    post "/token", TokenController, :create
  end

  # Content sync endpoint (authenticated via deployment key, not OAuth)
  scope "/api/content", CodeMySpecWeb do
    pipe_through :api

    post "/sync", ContentSyncController, :sync
    post "/pull", ContentSyncController, :pull
  end

  # Registered-users endpoint — CodeMySpec dogfoods its own ProjectUsers feature
  # by exposing its users (deploy-key Bearer auth, same as content sync).
  scope "/api/cms", CodeMySpecWeb do
    pipe_through :api

    get "/users", CmsUsersController, :index
  end

  # Framework issue intake from installed CLIs (deploy-key Bearer auth, no
  # OAuth — local-first installs have no token; the key resolves the project).
  scope "/api/framework", CodeMySpecWeb do
    pipe_through :api

    post "/issues", FrameworkIssuesController, :create
  end

  # Widget API (deploy-key Bearer auth, the key resolves the project). Desktop
  # apps push their end-users here — the counterpart to the pull-based
  # /api/cms/users integration web apps expose — so widget chat and issue
  # reporting have a durable identity.
  scope "/api/widget", CodeMySpecWeb do
    pipe_through :api

    post "/users", WidgetUsersController, :upsert

    # Issue intake from an end user of a generated app. Deploy-key auth on the
    # app, none on the reporter — someone hitting a bug in a shipped product has
    # no CodeMySpec account and should not need one to report it.
    post "/issues", WidgetIssuesController, :create
  end

  # Browser-safe socket credential. Behind the app token rather than the
  # deploy key: the point is to hand the browser something the deploy key
  # never becomes.
  scope "/api/widget", CodeMySpecWeb do
    pipe_through [:api, CodeMySpecWeb.Plugs.AppToken]

    get "/socket_token", WidgetSocketTokenController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:code_my_spec, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CodeMySpecWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview

      # Live view of `/dev/state`: each project's working copies, the analyzer
      # ledger's running/queued per source, and each source's current/next-run ceiling.
      live "/analysis", CodeMySpecWeb.DevAnalysisLive

      # Whether the requirement graph keeps up incrementally. Read-only; see
      # `DevGraphLive`.
      live "/graph", CodeMySpecWeb.DevGraphLive
    end

    # Cross-project agent control and QA fixtures. Inside `:dev_routes`, so absent
    # from a release, not disabled. See `DevAgentController`.
    scope "/dev", CodeMySpecWeb do
      pipe_through :api

      get "/agents", DevAgentController, :index
      post "/agents/:agent_id/message", DevAgentController, :message

      # A real session for QA without the shared `/dev/mailbox`: mints the same
      # "login" token the magic-link email carries, redeemed at the same route.
      post "/sign-in", DevSignInController, :create
      post "/sign-up", DevSignInController, :register

      post "/provisioning-fixtures", DevProvisioningFixtureController, :create

      # Agents for QA to act as against this copy's own app (story 1143).
      post "/qa-agents", DevProvisioningFixtureController, :qa_agents

      post "/provisioning-fixtures/:project_id/start-agent",
           DevProvisioningFixtureController,
           :start_agent

      post "/provisioning-fixtures/:project_id/prepare-agent",
           DevProvisioningFixtureController,
           :prepare_agent

      post "/provisioning-fixtures/:project_id/inspect",
           DevProvisioningFixtureController,
           :inspect_fixture

      post "/provisioning-fixtures/:project_id/control",
           DevProvisioningFixtureController,
           :control

      post "/agents/:agent_id/stop", DevAgentController, :stop

      post "/agents/:agent_id/restart", DevAgentController, :restart

      # `stop` turns an agent off; `restart` refuses an off one; `turn_on` is the
      # way back.
      post "/agents/:agent_id/turn_on", DevAgentController, :turn_on

      # Clear an agent parked on a question.
      get "/agents/:agent_id/questions", DevAgentController, :questions
      post "/agents/:agent_id/answer", DevAgentController, :answer

      # Staffing must run in the server's VM, where the channel registry lives; a
      # `mix run` script writes rows that reach no harness.
      post "/copies/:working_copy_id/staff", DevAgentController, :staff

      # The continuous switch alone, without restaffing.
      post "/copies/:working_copy_id/continuous", DevAgentController, :continuous

      # A copy's tool list by hand, so QA can produce a toolless copy
      # (`Machinery.tool_fault/1`) without breaking a shared MCP client. The next
      # harness join overwrites it.
      post "/copies/:working_copy_id/machine_tools", DevAgentController, :machine_tools

      # Per-caller failure injection, so failure criteria are testable on a shared box.
      get "/faults", DevFaultController, :index
      post "/faults", DevFaultController, :create
      delete "/faults", DevFaultController, :delete

      # Intake plan tokens, for intake faults: the session token is signed, so a
      # browser driver cannot read its own.
      get "/intake/plans", DevFaultController, :plans

      # Database belief versus runtime state, across every project.
      get "/state", DevStateController, :index

      # A GET so it needs only a URL. Not idempotent; answers which sources it
      # enqueued and which were current.
      get "/state/run", DevStateController, :run

      # Whether the agents are actually working: six fleet numbers.
      get "/fleet", DevStateController, :fleet
    end
  end

  ## Authentication routes

  scope "/app", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Defined before the `live "/mail/:id"` route so these literal paths win the
    # match — otherwise `/app/mail/image` binds `:id => "image"` on MailLive and
    # blows up casting "image" to a mailbox UUID.
    get "/mail/attachments/:id", MailAttachmentController, :show
    get "/mail/image", MailImageController, :show
    get "/issues/:id/screenshot", IssueScreenshotController, :show
    get "/qa_attempts/:attempt_id/evidence/:name", QaEvidenceController, :show
    get "/inbox/messages/:message_id/attachments/:index", ConversationAttachmentController, :show

    live_session :require_authenticated_user,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.Live.NotificationsHook, :default}
      ] do
      live "/", AppLive.Overview
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/preferences", UserPreferenceLive.Form, :edit
      live "/notifications", NotificationLive.Index, :index
      live "/permissions/:id", PermissionLive.Show, :show
      live "/questions/:id", QuestionLive.Show, :show
      live "/accounts", AccountLive.Index, :index
      live "/accounts/picker", AccountLive.Picker, :index
      live "/accounts/:id", AccountLive.Manage, :show
      live "/accounts/:id/manage", AccountLive.Manage, :show
      live "/accounts/:id/members", AccountLive.Members, :show
      live "/accounts/:id/invitations", AccountLive.Invitations, :show
      # Per user, whichever account is open: the credentials it names are.
      live "/agent-models", AgentModelsLive, :show
    end

    live_session :require_active_account,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_account},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.Live.NotificationsHook, :default}
      ] do
      live "/projects", ProjectLive.Index, :index
      live "/projects/picker", ProjectLive.Picker, :index
      live "/projects/new", ProjectLive.Form, :new
      live "/projects/:id", ProjectLive.Show, :show
      live "/projects/:id/edit", ProjectLive.Form, :edit

      # Account-scoped: a box belongs to the account and can serve several projects.
      live "/devices", DeviceLive.Index, :index
      live "/devices/provider/:name/edit", DeviceLive.Index, :edit
      live "/devices/provider/:name", DeviceLive.Show, :show
      live "/devices/:device_id", DeviceLive.Show, :show
      live "/servers", DeviceLive.Index, :index

      live "/servers/:name/edit", DeviceLive.Index, :edit
      live "/servers/:name", DeviceLive.Show, :show
    end

    # Project pages. The project is named in the route; `:assign_project` puts
    # it on `current_scope` and assigns `@project`.
    live_session :project,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_account},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.Live.NotificationsHook, :default},
        {CodeMySpecWeb.UserAuth, :assign_project}
      ] do
      # Static segments first so they win over `:id`.
      live "/projects/:project_id/console/devices/:device_id/setup", AppLive.LocalSetup
      live "/projects/:project_id/console/dev-boxes/:device_id/setup", AppLive.LocalSetup
      live "/projects/:project_id/init", InitLive, :index
      live "/projects/:project_id/init/:step", InitLive, :show

      live "/projects/:project_id/stories", StoryLive.Index, :index
      live "/projects/:project_id/stories/scheduler", StoryLive.Scheduler, :index
      live "/projects/:project_id/stories/new", StoryLive.Form, :new
      live "/projects/:project_id/stories/import", StoryLive.Import, :import
      live "/projects/:project_id/stories/:number", StoryLive.Show, :show
      live "/projects/:project_id/stories/:number/edit", StoryLive.Form, :edit
      live "/projects/:project_id/stories/:number/three-amigos", StoryLive.ThreeAmigos
      live "/projects/:project_id/stories/:number/gherkin", StoryLive.Gherkin

      live "/projects/:project_id/epics", EpicsLive.Index, :index
      live "/projects/:project_id/epics/new", EpicsLive.Index, :new
      live "/projects/:project_id/epics/:slug", EpicsLive.Show, :show
      live "/projects/:project_id/epics/:slug/edit", EpicsLive.Index, :edit

      live "/projects/:project_id/personas", PersonasLive.Index, :index
      live "/projects/:project_id/personas/new", PersonasLive.Index, :new
      live "/projects/:project_id/personas/:slug", PersonasLive.Show, :show
      live "/projects/:project_id/personas/:slug/edit", PersonasLive.Show, :edit
      live "/projects/:project_id/personas/:slug/link", PersonasLive.Show, :link

      live "/projects/:project_id/qa", QaLive
      live "/projects/:project_id/configuration", ConfigurationLive

      live "/projects/:project_id/issues", IssuesLive.Index, :index
      live "/projects/:project_id/issues/:id", IssuesLive.Show, :show

      live "/projects/:project_id/content", ContentLive
      live "/projects/:project_id/content/:id", ContentLive.Show
      live "/projects/:project_id/problems", ProblemsLive
      live "/projects/:project_id/runs/:run_id", RunLive

      live "/projects/:project_id/files", FilesLive
      live "/projects/:project_id/next-task", Tasks.NextTaskLive
      live "/projects/:project_id/tasks", Tasks.TaskQueueLive
      live "/projects/:project_id/architecture", ArchitectureLive, :dependency_graph
      live "/projects/:project_id/architecture/namespaces", ArchitectureLive, :namespaces

      live "/projects/:project_id/agent-performance", AgentPerformanceLive.Index, :index
      live "/projects/:project_id/agent-performance/:agent_id", AgentPerformanceLive.Show, :show

      # Docs: the project's own knowledge, then CodeMySpec's bundled guidance.
      # The old per-library paths still open the same page.
      live "/projects/:project_id/docs", MarkdownBrowserLive, :project_knowledge
      live "/projects/:project_id/docs/project/*path", MarkdownBrowserLive, :project_knowledge
      live "/projects/:project_id/docs/codemyspec/*path", MarkdownBrowserLive, :knowledge
      live "/projects/:project_id/knowledge/*path", MarkdownBrowserLive, :knowledge

      live "/projects/:project_id/project-knowledge/*path",
           MarkdownBrowserLive,
           :project_knowledge

      live "/projects/:project_id/requirements/graph", RequirementsLive, :graph

      live "/projects/:project_id/users", ProjectUsersLive.Index, :index

      live "/projects/:project_id/inbox", InboxLive, :index
      live "/projects/:project_id/inbox/:id", InboxLive, :show

      live "/projects/:project_id/mailboxes", MailboxLive, :index

      live "/projects/:project_id/mail", MailLive, :index
      live "/projects/:project_id/mail/:id", MailLive, :show

      # The project console. `?env=` scopes only resources and deploys.
      live "/projects/:project_id/console", ConsoleLive, :overview
      live "/projects/:project_id/console/resources", ConsoleLive, :resources
      live "/projects/:project_id/console/resources/:key", ConsoleLive, :resource_detail
      # The account's servers, in each project's console; `/app/servers` too.
      live "/projects/:project_id/console/servers", DeviceLive.Index, :index
      live "/projects/:project_id/console/servers/:name/edit", DeviceLive.Index, :edit
      live "/projects/:project_id/console/servers/:name", DeviceLive.Show, :show
      live "/projects/:project_id/console/inventory", ResourceLive.Index, :index
      live "/projects/:project_id/console/devices", DeviceLive.Index, :index
      live "/projects/:project_id/console/devices/provider/:name/edit", DeviceLive.Index, :edit
      live "/projects/:project_id/console/devices/provider/:name", DeviceLive.Show, :show
      live "/projects/:project_id/console/devices/:device_id", DeviceLive.Show, :show
      live "/projects/:project_id/console/dev-boxes", DeviceLive.Index, :index
      live "/projects/:project_id/console/deploys", ConsoleLive, :deploys
      live "/projects/:project_id/console/secrets", ConsoleLive, :secrets
      live "/projects/:project_id/console/credentials", ConsoleLive, :credentials
      live "/projects/:project_id/console/activity", ConsoleLive, :activity
      live "/projects/:project_id/console/settings", ConsoleLive, :settings
      live "/projects/:project_id/working-copies", WorkingCopyLive.Index, :index
      live "/projects/:project_id/working-copies/:id", WorkingCopyLive.Show, :show
      live "/projects/:project_id/working-copies/:id/edit", WorkingCopyLive.Form, :edit
      live "/projects/:project_id/working-copies/:id/status", WorkingCopyLive.Status, :status
      # The cockpit is a project page; which agent you read is `?conversation=<id>`,
      # so switching is a patch and the panels stay put.
      live "/projects/:project_id/agent-conversation", AgentConversationLive.Show, :show

      # The old path-style link (push notifications carry it); redirects to the
      # canonical URL.
      live "/projects/:project_id/agent-conversation/:conversation_id",
           AgentConversationLive.Show,
           :legacy_conversation_path

      # The list of agent conversations.
      live "/projects/:project_id/agent-conversations", AgentConversationLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # OAuth Provider routes — shared callback, two entry points
  scope "/auth", CodeMySpecWeb do
    pipe_through :browser

    # Social login (unauthenticated)
    get "/:provider/login", IntegrationsController, :login
    # Shared callback for both login and integration flows
    get "/:provider/callback", IntegrationsController, :callback
  end

  # The desktop app's loopback redirect (http://127.0.0.1:<port>/callback), the
  # one path Cloudflare's public client accepts. The provider is whichever flow
  # the returned state was parked under (CodeMySpec.Integrations.OAuthHandoff).
  scope "/", CodeMySpecWeb do
    pipe_through :browser

    get "/callback", IntegrationsController, :callback
  end

  scope "/auth", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Integration connect (authenticated)
    get "/:provider", IntegrationsController, :request
    delete "/:provider", IntegrationsController, :delete
  end

  scope "/", CodeMySpecWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/check-email", UserLive.CheckEmail, :new
      live "/users/log-in", UserLive.Login, :new
      live "/invitations/accept", InvitationsLive.Accept, :new
      live "/invitations/accept/:token", InvitationsLive.Accept, :new
    end

    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
