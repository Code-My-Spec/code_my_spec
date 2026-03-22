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

      live "/projects/:project_name/sync", SyncLive
      live "/projects/:project_name/requirements", RequirementsLive, :index
      live "/projects/:project_name/requirements/:name", RequirementsLive, :show
      live "/projects/:project_name/requirements/:name/:child_id", RequirementsLive, :child
      live "/projects/:project_name/graph", RequirementsLive, :graph
      live "/projects/:project_name/stories", RequirementsLive, :stories
      live "/projects/:project_name/stories/:story_id", RequirementsLive, :story_show
      live "/projects/:project_name/stories/:story_id/requirements/:name", RequirementsLive, :story_req_show
      live "/projects/:project_name/components/:component_id", RequirementsLive, :component_show
      live "/projects/:project_name/components/:component_id/requirements/:name", RequirementsLive, :component_req_show
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

  pipeline :project do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.ProjectScope
  end

  scope "/api/projects/:project_name", CodeMySpecLocalWeb do
    pipe_through :project

    post "/sync", SyncController, :create
    get "/requirements", RequirementsController, :index
    get "/requirements/:name", RequirementsController, :show
    get "/requirements/:name/prompt", RequirementsController, :prompt
    get "/requirements/:name/:child_id", RequirementsController, :child
    get "/graph", RequirementsGraphController, :show
    get "/stories", StoriesRequirementsController, :index
    get "/stories/:story_id", StoriesRequirementsController, :show
    get "/stories/:story_id/requirements/:name", StoriesRequirementsController, :show_requirement
    get "/components/:component_id", ComponentsRequirementsController, :show
    get "/components/:component_id/requirements/:name", ComponentsRequirementsController, :show_requirement
  end

  # ── Health check (no auth) ──────────────────────────────────────

  scope "/", CodeMySpecLocalWeb do
    get "/health", HealthController, :index
  end
end
