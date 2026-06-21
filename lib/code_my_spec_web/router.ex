defmodule CodeMySpecWeb.Router do
  use CodeMySpecWeb, :router

  import CodeMySpecWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodeMySpecWeb.Layouts, :root}
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

  scope "/", CodeMySpecWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/products/code-my-spec", PageController, :code_my_spec
    get "/products/market-my-spec", PageController, :market_my_spec_redirect
    get "/sitemap.xml", SitemapController, :index
    get "/llms.txt", LlmsTxtController, :index
    get "/llms-full.txt", LlmsTxtController, :full

    # Content index pages (dead views)
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
      live "/blog/agentic-marketing-with-mcp",
           ContentLive.Pages.AgenticMarketingWithMcp,
           :agentic_marketing_with_mcp
      live "/author/john-davenport", AuthorLive, :author
    end

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

    forward "/components", Anubis.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.ComponentsServer
  end

  # API routes
  scope "/api", CodeMySpecWeb do
    pipe_through [:api, :require_oauth_token, CodeMySpecWeb.Plugs.ProjectScopeOverride]

    get "/me", UserController, :me
    get "/projects", ProjectController, :index

    resources "/issues", IssuesController, only: [:index, :show, :create, :update]

    post "/uploads/presign", UploadController, :create

    post "/notifications/push", NotificationController, :push

    post "/permissions/request", PermissionController, :create
    post "/permissions/:id/respond", PermissionController, :respond
    get "/permissions/:id/status", PermissionController, :status
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

  # Content sync endpoint (authenticated via deployment key, not OAuth)
  scope "/api/content", CodeMySpecWeb do
    pipe_through :api

    post "/sync", ContentSyncController, :sync
  end

  # Registered-users endpoint — CodeMySpec dogfoods its own ProjectUsers feature
  # by exposing its users (deploy-key Bearer auth, same as content sync).
  scope "/api/cms", CodeMySpecWeb do
    pipe_through :api

    get "/users", CmsUsersController, :index
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

    live_session :require_authenticated_user,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated}
      ] do
      live "/", AppLive.Overview
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/preferences", UserPreferenceLive.Form, :edit
      live "/permissions/:id", PermissionLive.Show, :show
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
        {CodeMySpecWeb.UserAuth, :require_active_account}
      ] do
      live "/projects", ProjectLive.Index, :index
      live "/projects/picker", ProjectLive.Picker, :index
      live "/projects/new", ProjectLive.Form, :new
      live "/projects/:id", ProjectLive.Show, :show
      live "/projects/:id/edit", ProjectLive.Form, :edit
    end

    live_session :require_active_project,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_account},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.UserAuth, :require_at_least_one_project},
        {CodeMySpecWeb.UserAuth, :require_active_project}
      ] do
      live "/content_admin", ContentAdminLive.Index, :index
      live "/content_admin/:id", ContentAdminLive.Show, :show

      live "/issues", IssuesLive.Index, :index
      live "/issues/:id", IssuesLive.Show, :show

      live "/users", ProjectUsersLive.Index, :index
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
