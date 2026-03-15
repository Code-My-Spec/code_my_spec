defmodule CodeMySpecWeb.Router do
  use CodeMySpecWeb, :router

  import CodeMySpecWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CodeMySpecWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
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

    # Public content routes (CLIENT APP FUNCTIONALITY)
    live_session :public_content,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/blog", ContentLive.Index, :blog_index
      live "/blog/:slug", ContentLive.Public, :blog
      live "/pages/:slug", ContentLive.Public, :page
      live "/landing/:slug", ContentLive.Public, :landing
      live "/documentation/:slug", ContentLive.Public, :documentation
      live "/methodology", ContentLive.Pages.Methodology, :methodology
    end
  end

  # Protected content routes (CLIENT APP FUNCTIONALITY)
  scope "/private", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    live "/blog/:slug", ContentLive.Public, :private_blog
    live "/pages/:slug", ContentLive.Public, :private_page
    live "/landing/:slug", ContentLive.Public, :private_landing
    live "/documentation/:slug", ContentLive.Public, :private_documentation
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

    forward "/stories", Hermes.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.StoriesServer

    forward "/components", Hermes.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.ComponentsServer

    forward "/analytics-admin", Hermes.Server.Transport.StreamableHTTP.Plug,
      server: CodeMySpec.McpServers.AnalyticsAdminServer
  end

  # API routes
  scope "/api", CodeMySpecWeb do
    pipe_through [:api, :require_oauth_token, CodeMySpecWeb.Plugs.ProjectScopeOverride]

    get "/me", UserController, :me
    get "/projects", ProjectController, :index

    resources "/stories", StoriesController, except: [:new, :edit] do
      post "/set-component", StoriesController, :set_component
      post "/clear-component", StoriesController, :clear_component
    end

    get "/stories-list/project", StoriesController, :list_project_stories

    get "/stories-list/by-priority",
        StoriesController,
        :list_project_stories_by_priority

    get "/stories-list/unsatisfied", StoriesController, :list_unsatisfied_stories
    get "/stories-list/component/:component_id", StoriesController, :list_component_stories

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
        {CodeMySpecWeb.UserAuth, :require_active_account}
      ] do
      live "/projects", ProjectLive.Index, :index
      live "/projects/picker", ProjectLive.Picker, :index
      live "/projects/new", ProjectLive.Form, :new
      live "/projects/:id", ProjectLive.Show, :show
      live "/projects/:id/edit", ProjectLive.Form, :edit
      live "/projects/:id/setup", ProjectLive.SetupWizard, :show
    end

    live_session :require_active_project,
      on_mount: [
        {CodeMySpecWeb.Live.CurrentPathHook, :default},
        {CodeMySpecWeb.UserAuth, :require_authenticated},
        {CodeMySpecWeb.UserAuth, :require_active_account},
        {CodeMySpecWeb.UserAuth, :require_active_project}
      ] do
      live "/stories", StoryLive.Index, :index
      live "/stories/scheduler", StoryLive.Scheduler, :index
      live "/stories/new", StoryLive.Form, :new
      live "/stories/import", StoryLive.Import, :import
      live "/stories/:id", StoryLive.Show, :show
      live "/stories/:id/edit", StoryLive.Form, :edit

      live "/components", ComponentLive.Index, :index
      live "/components/new", ComponentLive.Form, :new
      live "/components/:id/edit", ComponentLive.Form, :edit

      live "/content_admin", ContentAdminLive.Index, :index
      live "/content_admin/:id", ContentAdminLive.Show, :show

      live "/architecture", ArchitectureLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # OAuth Provider Integration routes
  scope "/auth", CodeMySpecWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/:provider", IntegrationsController, :request
    get "/:provider/callback", IntegrationsController, :callback
    delete "/:provider", IntegrationsController, :delete
  end

  scope "/", CodeMySpecWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{CodeMySpecWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/invitations/accept", InvitationsLive.Accept, :new
      live "/invitations/accept/:token", InvitationsLive.Accept, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
