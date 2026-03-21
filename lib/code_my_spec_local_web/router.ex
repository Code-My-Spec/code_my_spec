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

      live "/setup", SetupLive, :index
      live "/setup/:step", SetupLive, :show
      live "/setup/:step/prompt", SetupLive, :prompt
    end
  end

  # ── LLM API (Controllers, markdown) ─────────────────────────────

  pipeline :api do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
  end

  pipeline :api_with_scope do
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
    plug CodeMySpecLocalWeb.Plugs.LocalScope
  end

  scope "/api/init", CodeMySpecLocalWeb do
    pipe_through :api

    get "/", InitController, :index
    get "/:step", InitController, :show
    get "/:step/prompt", InitController, :prompt
  end

  scope "/api/setup", CodeMySpecLocalWeb do
    pipe_through :api_with_scope

    get "/", SetupController, :index
    get "/:step", SetupController, :show
    get "/:step/prompt", SetupController, :prompt
  end

  # ── Legacy routes (tasks, not yet migrated to LiveView) ─────────

  pipeline :local_with_scope do
    plug :accepts, ["html", "json", "text"]
    plug CodeMySpecLocalWeb.Plugs.LocalOnly
    plug CodeMySpecLocalWeb.Plugs.WorkingDir
    plug CodeMySpecLocalWeb.Plugs.LocalScope
  end

  scope "/tasks", CodeMySpecLocalWeb do
    pipe_through :local_with_scope

    get "/graph", TaskGraphController, :show
  end

  # ── Health check (no auth) ──────────────────────────────────────

  scope "/", CodeMySpecLocalWeb do
    get "/health", HealthController, :index
  end
end
