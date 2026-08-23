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
  end

  # Guided intake (story 990). Its own pipeline because the anonymous plan
  # token has to be minted before the LiveView mounts — a LiveView cannot
  # write the session itself.
  pipeline :intake do
    plug CodeMySpecWeb.Plugs.IntakeSession
  end

  scope "/", CodeMySpecWeb do
    pipe_through [:browser, :intake]

    live_session :intake,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/build", IntakeLive.Plan, :plan
    end

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
    # The intake starts on the home page, so the home page needs a session
    # token to start it against — the same anonymous token /build reads, so a
    # visitor who begins here and continues there is one plan, not two.
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

    # Tag-filtered index pages (story 713) — 3-segment, declared before the
    # 2-segment :slug routes for clarity.
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
  end

  # OAuth2 API endpoints (no CSRF protection)
  scope "/oauth", CodeMySpecWeb do
    pipe_through :api

    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
    post "/register", OAuthController, :register
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

    # The harness tools, served from the server rather than from a process on
    # the developer's machine.
    #
    # Scope arrives the same way it does for every other server-mounted MCP
    # server: `require_oauth_token` identifies the user and
    # `ProjectScopeOverride` picks the project from `X-Project-ID`. Anubis
    # copies `conn.assigns` wholesale into the request context, so the
    # `current_scope` those plugs build reaches the tools untouched — which is
    # the same route `working_dir` takes on the local mount.
    #
    # `Validators.validate_local_scope/2` already prefers a frame scope that
    # carries an `active_project_id` and only falls back to resolving one from a
    # working directory. Here there is no working directory and no fallback: a
    # request without a project is refused rather than guessed at.
    forward "/harness", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.LocalServer

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

    # One project's authored graph, one request, one transaction (story 991).
    post "/migrations", MigrationsController, :create

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

    post "/questions/ask", QuestionController, :ask
    post "/questions/:id/answer", QuestionController, :answer
    get "/questions/:id/status", QuestionController, :status

    # Where a harness is. The harness has an id and needs a directory; this is
    # the side that knows, and keeping it here is what lets the harness hold no
    # local record of working copies at all.
    get "/harnesses/:id", HarnessLookupController, :show
    post "/harnesses", HarnessLookupController, :create
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

  # The one endpoint a deployed app's refresh secret opens. Everything else it
  # calls takes the short-lived token this returns — story 971's property is
  # not "the app holds no durable secret" (it holds one) but that what it
  # holds opens none of the five surfaces.
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

  # (analytics/event route removed — browser events fire via gtag.js directly)

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:code_my_spec, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CodeMySpecWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
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

      # Account-scoped rather than project-scoped, which is the whole point of
      # story 994: a box belongs to the account and can serve several
      # projects. Putting it behind `:project_scoped` would reintroduce the
      # grain this exists to fix, and would hide Sam's own servers behind
      # having picked a project first.
      live "/resources", ResourceLive.Index, :index
      live "/servers", ServerLive.Index, :index
      live "/servers/:name/edit", ServerLive.Index, :edit
      live "/servers/:name", ServerLive.Show, :show
    end

    # Portable UI — these LiveViews are mounted by CodeMySpecLocalWeb.Router
    # at the same paths. `layout:` picks the cloud chrome, `on_mount` supplies
    # the scope; nothing app-specific is baked into the views themselves.
    # Same path shape as the local mount is what lets them keep plain `~p`.
    live_session :portable,
      layout: {CodeMySpecWeb.Layouts, :live},
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_account},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.Live.NotificationsHook, :default},
        {CodeMySpecWeb.PortableHost, :default}
      ] do
      # Static segments first so they win over `:id`.
      live "/projects/:project_id/init", InitLive, :index
      live "/projects/:project_id/init/:step", InitLive, :show

      live "/projects/:project_id/stories", StoryLive.Index, :index
      live "/projects/:project_id/stories/scheduler", StoryLive.Scheduler, :index
      live "/projects/:project_id/stories/new", StoryLive.Form, :new
      live "/projects/:project_id/stories/import", StoryLive.Import, :import
      live "/projects/:project_id/stories/:id", StoryLive.Show, :show
      live "/projects/:project_id/stories/:id/edit", StoryLive.Form, :edit
      live "/projects/:project_id/stories/:id/three-amigos", StoryLive.ThreeAmigos
      live "/projects/:project_id/stories/:id/gherkin", StoryLive.Gherkin

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
      live "/projects/:project_id/sessions", SessionsLive, :index
      live "/projects/:project_id/sessions/:id", SessionsLive, :show
      live "/projects/:project_id/sessions/:id/tasks/:task_id", SessionsLive, :task_show

      live "/projects/:project_id/files", FilesLive
      live "/projects/:project_id/next-task", Tasks.NextTaskLive
      live "/projects/:project_id/tasks", Tasks.TaskQueueLive
      live "/projects/:project_id/progress", AgentProgressLive
      live "/projects/:project_id/architecture", ArchitectureLive, :dependency_graph
      live "/projects/:project_id/architecture/overview", ArchitectureLive, :overview
      live "/projects/:project_id/architecture/namespaces", ArchitectureLive, :namespaces
      live "/projects/:project_id/knowledge", MarkdownBrowserLive, :knowledge
      live "/projects/:project_id/knowledge/*path", MarkdownBrowserLive, :knowledge
      live "/projects/:project_id/project-knowledge", MarkdownBrowserLive, :project_knowledge

      live "/projects/:project_id/project-knowledge/*path",
           MarkdownBrowserLive,
           :project_knowledge

      # Brownfield onboarding, deliberately not under /requirements/. It stopped
      # being a requirement when `cms new` took over setup — a generated project
      # exits with it complete — so it is a door into the workflow rather than a
      # step in it. See `ProjectSetupLive`.
      live "/projects/:project_id/setup", ProjectSetupLive, :show
      live "/projects/:project_id/setup/:step_id", ProjectSetupLive, :step

      live "/projects/:project_id/requirements", RequirementsLive, :index
      live "/projects/:project_id/requirements/graph", RequirementsLive, :graph
      live "/projects/:project_id/requirements/stories", RequirementsLive, :stories
      live "/projects/:project_id/requirements/:name", RequirementsLive, :show
      live "/projects/:project_id/components", RequirementsLive, :components
      live "/projects/:project_id/components/graph", RequirementsLive, :components_graph
      live "/projects/:project_id/components/:component_id", RequirementsLive, :component_show

      live "/projects/:project_id/components/:component_id/graph",
           RequirementsLive,
           :component_graph

      live "/projects/:project_id/components/:component_id/requirements/:name",
           RequirementsLive,
           :component_req_show

      live "/projects/:project_id/components/:component_id/requirements/:name/prompt",
           RequirementsLive,
           :component_req_prompt

      live "/projects/:project_id/stories/:story_id/requirements/:name",
           RequirementsLive,
           :story_req_show
    end

    # Project-scoped surfaces. The project is named in the route and put on the
    # scope by PortableHost — there is no session-held active project to fall
    # back on, which is why every one of these carries :project_id.
    live_session :project_scoped,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_account},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_project},
        {CodeMySpecWeb.Live.NotificationsHook, :default},
        {CodeMySpecWeb.PortableHost, :default}
      ] do
      live "/projects/:project_id/users", ProjectUsersLive.Index, :index

      live "/projects/:project_id/chat", ChatLive, :show
      live "/projects/:project_id/inbox", InboxLive, :index
      live "/projects/:project_id/inbox/:id", InboxLive, :show

      live "/projects/:project_id/mailboxes", MailboxLive, :index

      live "/projects/:project_id/mail", MailLive, :index
      live "/projects/:project_id/mail/:id", MailLive, :show

      live "/projects/:project_id/provisioning", ProvisioningLive, :index
      live "/projects/:project_id/working-copies", WorkingCopiesLive, :index
      live "/projects/:project_id/agent-conversation", AgentConversationLive.Index, :index

      live "/projects/:project_id/agent-conversation/:conversation_id",
           AgentConversationLive.Show,
           :show
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
