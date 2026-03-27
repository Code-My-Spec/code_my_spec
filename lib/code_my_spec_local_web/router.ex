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

      live "/init", InitLive, :index
      live "/init/:step", InitLive, :show
      live "/init/:step/prompt", InitLive, :prompt

      live "/projects/:project_name", HomeLive
      live "/projects/:project_name/sync", SyncLive
      live "/projects/:project_name/next-task", Tasks.NextTaskLive
      live "/projects/:project_name/requirements", RequirementsLive, :index
      live "/projects/:project_name/requirements/:name", RequirementsLive, :show
      live "/projects/:project_name/requirements/:name/:child_id", RequirementsLive, :child
      live "/projects/:project_name/graph", RequirementsLive, :graph
      live "/projects/:project_name/stories", StoriesLive, :index
      live "/projects/:project_name/stories/requirements", RequirementsLive, :stories
      live "/projects/:project_name/stories/:story_id", StoriesLive, :show
      live "/projects/:project_name/stories/:story_id/requirements", RequirementsLive, :story_show

      live "/projects/:project_name/stories/:story_id/requirements/:name",
           RequirementsLive,
           :story_req_show

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

      live "/projects/:project_name/components", RequirementsLive, :components
      live "/projects/:project_name/components/:component_id", RequirementsLive, :component_show

      live "/projects/:project_name/components/:component_id/requirements/:name",
           RequirementsLive,
           :component_req_show
    end
  end

  # ── LLM API (Controllers, markdown) ─────────────────────────────

  pipeline :api do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
  end

  scope "/api/init", CodeMySpecLocalWeb do
    pipe_through :api

    get "/", InitController, :index
    get "/:step", InitController, :show
    get "/:step/prompt", InitController, :prompt
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
  end

  pipeline :project do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.ProjectScope
  end

  scope "/api/projects/:project_name", CodeMySpecLocalWeb do
    pipe_through :project

    post "/sync", SyncController, :create
    # next-task moved to MCP (DraftTask tool); LiveView preview stays
    get "/next-task", NextTaskController, :show
    get "/requirements", RequirementsController, :index
    get "/requirements/:name", RequirementsController, :show
    get "/requirements/:name/prompt", RequirementsController, :prompt
    get "/requirements/:name/:child_id", RequirementsController, :child
    get "/graph", RequirementsGraphController, :show
    get "/stories", StoriesController, :index
    get "/stories/:story_id", StoriesController, :show
    post "/stories/:story_id/set-component", StoriesController, :set_component
    get "/stories/requirements", StoriesRequirementsController, :index
    get "/stories/:story_id/requirements", StoriesRequirementsController, :show
    get "/stories/:story_id/requirements/:name", StoriesRequirementsController, :show_requirement
    get "/sessions", SessionsController, :index
    get "/sessions/:id", SessionsController, :show
    get "/sessions/:session_id/tasks/:task_id", SessionsController, :show_task
    # start-task and evaluate-task moved to MCP (StartTask, EvaluateTask tools)
    get "/knowledge", MarkdownBrowserController, :index
    get "/knowledge/*path", MarkdownBrowserController, :show
    get "/project-knowledge", MarkdownBrowserController, :index
    get "/project-knowledge/*path", MarkdownBrowserController, :show
    # issues API removed — use MCP tools (ListIssues, GetIssue)
    get "/components/requirements", ComponentsRequirementsController, :index
    get "/components/:component_id/requirements", ComponentsRequirementsController, :show

    get "/components/:component_id/requirements/:name",
        ComponentsRequirementsController,
        :show_requirement
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
