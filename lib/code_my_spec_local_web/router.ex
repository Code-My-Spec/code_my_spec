defmodule CodeMySpecLocalWeb.Router do
  use CodeMySpecLocalWeb, :router

  # ── Human UI (LiveView) ──────────────────────────────────────────

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {CodeMySpecLocalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
  end

  live_session :local do
    scope "/", CodeMySpecLocalWeb do
      pipe_through :browser

      live "/auth", AuthLive, :index

      live "/", ProjectsLive.Index, :index
      live "/projects", ProjectsLive.Index, :index
      live "/projects/:project_name", HomeLive
      live "/projects/:project_name/init", InitLive, :index
      live "/projects/:project_name/init/:step", InitLive, :show
      live "/projects/:project_name/configuration", ConfigurationLive
      live "/projects/:project_name/sync", SyncLive
      live "/projects/:project_name/next-task", Tasks.NextTaskLive
      live "/projects/:project_name/requirements", RequirementsLive, :index
      live "/projects/:project_name/requirements/graph", RequirementsLive, :graph
      live "/projects/:project_name/requirements/:name", RequirementsLive, :show
      live "/projects/:project_name/requirements/:name/:child_id", RequirementsLive, :child

      live "/projects/:project_name/components", RequirementsLive, :components
      live "/projects/:project_name/components/graph", RequirementsLive, :components_graph
      live "/projects/:project_name/components/:component_id", RequirementsLive, :component_show
      live "/projects/:project_name/components/:component_id/graph", RequirementsLive, :component_graph
      live "/projects/:project_name/components/:component_id/requirements/:name", RequirementsLive, :component_req_show
      live "/projects/:project_name/components/:component_id/requirements/:name/prompt", RequirementsLive, :component_req_prompt

      live "/projects/:project_name/stories", RequirementsLive, :stories
      live "/projects/:project_name/stories/:story_id", RequirementsLive, :story_show
      live "/projects/:project_name/stories/:story_id/requirements/:name", RequirementsLive, :story_req_show

      live "/projects/:project_name/architecture", ArchitectureLive, :dependency_graph
      live "/projects/:project_name/architecture/overview", ArchitectureLive, :overview
      live "/projects/:project_name/architecture/namespaces", ArchitectureLive, :namespaces
      live "/projects/:project_name/issues", IssuesLive.Index, :index
      live "/projects/:project_name/issues/:id", IssuesLive.Show, :show
      live "/projects/:project_name/sessions", SessionsLive, :index
      live "/projects/:project_name/sessions/:id", SessionsLive, :show
      live "/projects/:project_name/sessions/:id/tasks/:task_id", SessionsLive, :task_show
      live "/projects/:project_name/knowledge", MarkdownBrowserLive, :knowledge
      live "/projects/:project_name/knowledge/*path", MarkdownBrowserLive, :knowledge
      live "/projects/:project_name/project-knowledge", MarkdownBrowserLive, :project_knowledge

      live "/projects/:project_name/project-knowledge/*path",
           MarkdownBrowserLive,
           :project_knowledge
    end
  end

  # ── Bootstrap (OAuth flow, no scope needed) ─────────────────────

  pipeline :bootstrap do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
  end

  scope "/api/bootstrap", CodeMySpecLocalWeb do
    pipe_through :bootstrap

    get "/auth/status", BootstrapController, :auth_status
    post "/auth/start", BootstrapController, :auth_start
    get "/auth/callback", BootstrapController, :auth_callback
    get "/projects", BootstrapController, :list_projects
  end

  # ── LLM API (Controllers, markdown) ─────────────────────────────

  pipeline :api do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
  end

  # Hook endpoints — resolve scope from X-Working-Dir header
  pipeline :hook do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
    plug CodeMySpecLocalWeb.Plugs.WorkingDirScope
  end

  scope "/api/hooks", CodeMySpecLocalWeb.Hooks do
    pipe_through :hook

    post "/session-start", SessionStartController, :handle
    post "/pre-tool-use", PreToolUseController, :handle
    post "/post-tool-use", PostToolUseController, :handle
    post "/stop", StopController, :handle
    post "/subagent-stop", SubagentStopController, :handle
    post "/notification", NotificationHookController, :handle
  end

  # ── Agent tasks (skill-invoked) ──────────────────────────────────

  scope "/api", CodeMySpecLocalWeb do
    pipe_through :hook

    post "/agent-tasks/start", SkillController, :start_task
    post "/skills/start", SkillController, :start_skill
  end

  # ── External integrations (notifications, permissions) ──────────

  scope "/api", CodeMySpecLocalWeb do
    pipe_through :hook

    post "/notifications/send", NotificationController, :send_notification
    post "/permissions/request", PermissionController, :create
  end

  scope "/api/permissions", CodeMySpecLocalWeb do
    pipe_through :bootstrap

    get "/:id/stream", PermissionController, :stream
    post "/:id/respond", PermissionController, :respond
  end

  pipeline :project do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.ProjectScope
  end

  scope "/api/projects/:project_name", CodeMySpecLocalWeb do
    pipe_through :project

    get "/requirements", RequirementsController, :index
    get "/requirements/:name", RequirementsController, :show
    get "/requirements/:name/prompt", RequirementsController, :prompt
    get "/requirements/:name/:child_id", RequirementsController, :child

    get "/components", ComponentsRequirementsController, :index
    get "/components/:component_id", ComponentsRequirementsController, :show
    get "/components/:component_id/requirements/:name", ComponentsRequirementsController, :show_requirement

    get "/stories", StoriesRequirementsController, :index
    get "/stories/:story_id", StoriesRequirementsController, :show
    get "/stories/:story_id/requirements/:name", StoriesRequirementsController, :show_requirement

    get "/knowledge", MarkdownBrowserController, :index
    get "/knowledge/*path", MarkdownBrowserController, :show
    get "/project-knowledge", MarkdownBrowserController, :index
    get "/project-knowledge/*path", MarkdownBrowserController, :show
  end

  # ── MCP (Streamable HTTP) ──────────────────────────────────────

  pipeline :mcp do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
  end

  scope "/mcp", CodeMySpecLocalWeb do
    pipe_through :mcp

    forward "/", McpPlug, server: CodeMySpec.McpServers.LocalServer
  end

  # ── Health check (no auth) ──────────────────────────────────────

  scope "/", CodeMySpecLocalWeb do
    get "/health", HealthController, :index
  end
end
