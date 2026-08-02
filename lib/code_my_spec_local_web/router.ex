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

      live "/app/auth", AuthLive, :index

      # Everything lives under /app so the local routes match the cloud's,
      # which is what lets one LiveView be mounted by both routers. `/` stays
      # as the local app's landing surface — it's what a developer types.
      live "/", ProjectsLive.Index, :index
      live "/app", ProjectsLive.Index, :index
      live "/app/projects", ProjectsLive.Index, :index
      live "/app/projects/new", ProjectsLive.Form, :new
      live "/app/projects/:project_name", HomeLive
      live "/app/projects/:project_name/edit", ProjectsLive.Form, :edit
      live "/app/projects/:project_name/files", FilesLive
      live "/app/projects/:project_name/init", InitLive, :index
      live "/app/projects/:project_name/init/:step", InitLive, :show
      live "/app/projects/:project_name/next-task", Tasks.NextTaskLive
      live "/app/projects/:project_name/tasks", Tasks.TaskQueueLive
      live "/app/projects/:project_name/progress", AgentProgressLive
      live "/app/projects/:project_name/requirements", RequirementsLive, :index
      live "/app/projects/:project_name/requirements/graph", RequirementsLive, :graph
      # Requirements view of stories (graph projection — distinct from admin).
      # Must come before the `:name` catch-all below.
      live "/app/projects/:project_name/requirements/stories", RequirementsLive, :stories
      live "/app/projects/:project_name/requirements/:name", RequirementsLive, :show
      live "/app/projects/:project_name/requirements/:name/:child_id", RequirementsLive, :child

      live "/app/projects/:project_name/architecture", ArchitectureLive, :dependency_graph
      live "/app/projects/:project_name/architecture/overview", ArchitectureLive, :overview
      live "/app/projects/:project_name/architecture/namespaces", ArchitectureLive, :namespaces

      live "/app/projects/:project_name/components", RequirementsLive, :components
      live "/app/projects/:project_name/components/graph", RequirementsLive, :components_graph
      live "/app/projects/:project_name/components/:component_id", RequirementsLive, :component_show

      live "/app/projects/:project_name/components/:component_id/graph",
           RequirementsLive,
           :component_graph

      live "/app/projects/:project_name/components/:component_id/requirements/:name",
           RequirementsLive,
           :component_req_show

      live "/app/projects/:project_name/components/:component_id/requirements/:name/prompt",
           RequirementsLive,
           :component_req_prompt

      # Requirements view of a story (graph projection — distinct from admin Show)
      live "/app/projects/:project_name/stories/:story_id/requirements/:name",
           RequirementsLive,
           :story_req_show

      live "/app/projects/:project_name/knowledge", MarkdownBrowserLive, :knowledge
      live "/app/projects/:project_name/knowledge/*path", MarkdownBrowserLive, :knowledge
      live "/app/projects/:project_name/project-knowledge", MarkdownBrowserLive, :project_knowledge

      live "/app/projects/:project_name/project-knowledge/*path",
           MarkdownBrowserLive,
           :project_knowledge
    end

  end

  # ── Portable UI ──────────────────────────────────────────────────
  #
  # These LiveViews live in `CodeMySpecWeb` and are mounted by the cloud
  # router too, at the same paths. Nothing app-specific is baked into them:
  # `layout:` picks the terminal chrome, `on_mount` supplies the local scope.
  # Migrating a surface out of `live_session :local` means moving its routes
  # here and deleting its layout wrapper — see `CodeMySpecLocalWeb.PortableHost`.
  #
  # Its own `scope` block because the `CodeMySpecLocalWeb` alias above would
  # otherwise resolve these to `CodeMySpecLocalWeb.CodeMySpecWeb.*`.
  live_session :portable,
    on_mount: [{CodeMySpecLocalWeb.PortableHost, :default}],
    layout: {CodeMySpecLocalWeb.Layouts, :live} do
    scope "/", CodeMySpecWeb do
      pipe_through :browser

      # Static segments first so they win over `:id`.
      live "/app/projects/:project_id/stories", StoryLive.Index, :index
      live "/app/projects/:project_id/stories/scheduler", StoryLive.Scheduler, :index
      live "/app/projects/:project_id/stories/new", StoryLive.Form, :new
      live "/app/projects/:project_id/stories/import", StoryLive.Import, :import
      live "/app/projects/:project_id/stories/:id", StoryLive.Show, :show
      live "/app/projects/:project_id/stories/:id/edit", StoryLive.Form, :edit
      live "/app/projects/:project_id/stories/:id/three-amigos", StoryLive.ThreeAmigos
      live "/app/projects/:project_id/stories/:id/gherkin", StoryLive.Gherkin

      # Epics — static segments first so they win over `:slug`
      live "/app/projects/:project_id/epics", EpicsLive.Index, :index
      live "/app/projects/:project_id/epics/new", EpicsLive.Index, :new
      live "/app/projects/:project_id/epics/:slug", EpicsLive.Show, :show
      live "/app/projects/:project_id/epics/:slug/edit", EpicsLive.Index, :edit

      live "/app/projects/:project_id/personas", PersonasLive.Index, :index
      live "/app/projects/:project_id/personas/new", PersonasLive.Index, :new
      live "/app/projects/:project_id/personas/:slug", PersonasLive.Show, :show
      live "/app/projects/:project_id/personas/:slug/edit", PersonasLive.Show, :edit
      live "/app/projects/:project_id/personas/:slug/link", PersonasLive.Show, :link

      live "/app/projects/:project_id/qa", QaLive
      live "/app/projects/:project_id/configuration", ConfigurationLive

      live "/app/projects/:project_id/issues", IssuesLive.Index, :index
      live "/app/projects/:project_id/issues/:id", IssuesLive.Show, :show

      live "/app/projects/:project_id/content", ContentLive
      live "/app/projects/:project_id/content/:id", ContentLive.Show
      live "/app/projects/:project_id/problems", ProblemsLive
      live "/app/projects/:project_id/sessions", SessionsLive, :index
      live "/app/projects/:project_id/sessions/:id", SessionsLive, :show
      live "/app/projects/:project_id/sessions/:id/tasks/:task_id", SessionsLive, :task_show
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

  # Antigravity hook endpoints — same scope chain, but the workspace
  # arrives as `workspacePaths` in the JSON body instead of a header
  pipeline :antigravity_hook do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.AntigravityWorkspace
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
    plug CodeMySpecLocalWeb.Plugs.WorkingDirScope
  end

  # Bootstrap endpoints — cwd-only scope, runnable before a project is linked
  pipeline :init do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
    plug CodeMySpecLocalWeb.Plugs.WorkingDirCwdScope
  end

  scope "/api/hooks", CodeMySpecLocalWeb.Hooks do
    pipe_through :hook

    post "/session-start", SessionStartController, :handle
    post "/pre-tool-use", PreToolUseController, :handle
    post "/post-tool-use", PostToolUseController, :handle
    post "/stop", StopController, :handle
    post "/subagent-start", SubagentStartController, :handle
    post "/subagent-stop", SubagentStopController, :handle
    post "/notification", NotificationHookController, :handle
    post "/ask-user-question", AskUserQuestionController, :handle
  end

  scope "/api/antigravity/hooks", CodeMySpecLocalWeb.Antigravity do
    pipe_through :antigravity_hook

    post "/pre-invocation", HooksController, :pre_invocation
    post "/pre-tool-use", HooksController, :pre_tool_use
    post "/post-tool-use", HooksController, :post_tool_use
    post "/post-invocation", HooksController, :post_invocation
    post "/stop", HooksController, :stop
  end

  # ── Agent tasks (skill-invoked) ──────────────────────────────────

  scope "/api", CodeMySpecLocalWeb do
    pipe_through :hook

    post "/agent-tasks/start", SkillController, :start_task
    post "/skills/start", SkillController, :start_skill

    # Model-facing analyzer runs — the PreToolUse hook rewrites agent
    # `mix test` / `mix spex` commands into a curl against this endpoint,
    # so model-invoked and stop-hook-invoked runs share one record.
    post "/analysis/run", AnalysisController, :run
  end

  # Init runs before a project is linked, so it gets the cwd-only :init
  # pipeline instead of the project-required :hook pipeline.
  scope "/api", CodeMySpecLocalWeb do
    pipe_through :init

    post "/skills/init", InitController, :start
  end

  # ── External integrations (notifications, permissions) ──────────

  scope "/api", CodeMySpecLocalWeb do
    pipe_through :hook

    post "/notifications/send", NotificationController, :send_notification
    post "/permissions/request", PermissionController, :create
  end

  scope "/api/permissions", CodeMySpecLocalWeb do
    pipe_through :bootstrap

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

    get "/components/:component_id/requirements/:name",
        ComponentsRequirementsController,
        :show_requirement

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
