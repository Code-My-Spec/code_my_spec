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
      live "/app/projects/:project_id", HomeLive

      # Everything lives under /app so the local routes match the cloud's,
      # which is what lets one LiveView be mounted by both routers. `/` stays
      # as the local app's landing surface — it's what a developer types.
      live "/", ProjectsLive.Index, :index
      live "/app", ProjectsLive.Index, :index
      live "/app/projects", ProjectsLive.Index, :index
      live "/app/projects/new", ProjectsLive.Form, :new
      live "/app/projects/:id/edit", ProjectsLive.Form, :edit
      # Requirements view of stories (graph projection — distinct from admin).
      # Must come before the `:name` catch-all below.

      # Requirements view of a story (graph projection — distinct from admin Show)
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
      live "/app/projects/:project_id/init", InitLive, :index
      live "/app/projects/:project_id/init/:step", InitLive, :show

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

      live "/app/projects/:project_id/files", FilesLive
      live "/app/projects/:project_id/next-task", Tasks.NextTaskLive
      live "/app/projects/:project_id/tasks", Tasks.TaskQueueLive
      live "/app/projects/:project_id/progress", AgentProgressLive
      live "/app/projects/:project_id/architecture", ArchitectureLive, :dependency_graph
      live "/app/projects/:project_id/architecture/overview", ArchitectureLive, :overview
      live "/app/projects/:project_id/architecture/namespaces", ArchitectureLive, :namespaces
      live "/app/projects/:project_id/knowledge", MarkdownBrowserLive, :knowledge
      live "/app/projects/:project_id/knowledge/*path", MarkdownBrowserLive, :knowledge
      live "/app/projects/:project_id/project-knowledge", MarkdownBrowserLive, :project_knowledge

      live "/app/projects/:project_id/project-knowledge/*path",
           MarkdownBrowserLive,
           :project_knowledge

      # Brownfield onboarding, deliberately not under /requirements/. It stopped
      # being a requirement when `cms new` took over setup — a generated project
      # exits with it complete — so it is a door into the workflow rather than a
      # step in it. See `ProjectSetupLive`.
      live "/app/projects/:project_id/setup", ProjectSetupLive, :show
      live "/app/projects/:project_id/setup/:step_id", ProjectSetupLive, :step

      live "/app/projects/:project_id/requirements", RequirementsLive, :index
      live "/app/projects/:project_id/requirements/graph", RequirementsLive, :graph
      live "/app/projects/:project_id/requirements/stories", RequirementsLive, :stories
      live "/app/projects/:project_id/requirements/:name", RequirementsLive, :show
      live "/app/projects/:project_id/components", RequirementsLive, :components
      live "/app/projects/:project_id/components/graph", RequirementsLive, :components_graph
      live "/app/projects/:project_id/components/:component_id", RequirementsLive, :component_show

      live "/app/projects/:project_id/components/:component_id/graph",
           RequirementsLive,
           :component_graph

      live "/app/projects/:project_id/components/:component_id/requirements/:name",
           RequirementsLive,
           :component_req_show

      live "/app/projects/:project_id/components/:component_id/requirements/:name/prompt",
           RequirementsLive,
           :component_req_prompt

      live "/app/projects/:project_id/stories/:story_id/requirements/:name",
           RequirementsLive,
           :story_req_show
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

  # Hook endpoints — scope comes from the X-Harness-Id header and nothing else.
  #
  # The fallback that used to sit here read a directory off the wire and walked
  # up to the nearest mix.exs. That resolved one session differently depending
  # on which subdirectory it fired from, resolved a nested checkout to the outer
  # one, and could not tell two checkouts at the same path on different machines
  # apart at all. Worse, a wrong path did not fail — it succeeded against the
  # wrong disk, which is how eight spec stubs ended up in the server's own
  # repository and `install_agents_md` reported success into a checkout nobody
  # asked it to touch.
  #
  # The working copy still knows where it is: `.cms_harness.json` holds
  # `{harness_id, project_id, root}` at its root, and `harnesses.root` mirrors
  # it. So the directory travels in config, next to the id that authorises it,
  # and never on the wire. An unknown id fails closed.
  pipeline :hook do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.HarnessScope
  end

  # Antigravity hooks route by id like every other hook. `AntigravityWorkspace`
  # dug a workspace path out of the JSON body, which was the same
  # directory-on-the-wire in a different shape — and the cost the identity
  # decision names by name: every transport parsing identity out of its own
  # payload format.
  pipeline :antigravity_hook do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.HarnessScope
  end

  # Nothing but the localhost check — for routes that name what they mean
  # instead of having it resolved for them.
  pipeline :local_only do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
  end

  # Init, and only init. It runs before anything has been onboarded, so there is
  # no harness id to route on — issuing one is downstream of what init does. It
  # is told its directory outright and refuses without, which is the one thing
  # the old chain never did: that one guessed, by walking up to a mix.exs.
  pipeline :init do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.InitCwd
  end

  # Onboarding. Names its project and root explicitly, so it is the one route
  # that cannot go through :hook — nothing has an id to route on yet.
  scope "/api", CodeMySpecLocalWeb do
    pipe_through :local_only

    post "/harnesses/register", HarnessController, :register
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

    # Blocks until the background analyzers are idle. The agent fires this in
    # the background and is notified when it returns — which is why it is here
    # and not an MCP tool: MCP caps a request at 30s and a sweep is 200-590s.
    post "/analysis/wait", AnalysisController, :wait
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

  # The same identity resolution the hooks get, and for the same reason.
  #
  # This ran `LocalOnly` and `WorkingDir` only, so an MCP tool received a scope
  # naming a project but no working copy — no `cwd`, no `environment`. Every
  # tool that writes to disk then refused: `create_component` told agents "this
  # server has no working copy, so the stub spec was not written" and handed
  # them the stub to type out by hand, which reads as a limitation of the light
  # harness rather than a missing plug.
  #
  # `HarnessScope` resolves the working copy from the id the checkout wrote down
  # (`.cms_harness.json`, mirrored on `harnesses.root`) and builds the scope
  # through `Scope.for_local_project/2`, which is what attaches the environment.
  #
  # The `?dir=` query parameter this used to accept is gone with the rest of
  # working-directory resolution: a path on the wire is a client-supplied
  # filesystem location the server then writes to, and a wrong one succeeds
  # against the wrong disk rather than failing.
  pipeline :mcp do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.HarnessScope
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
