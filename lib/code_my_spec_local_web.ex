defmodule CodeMySpecLocalWeb do
  @moduledoc """
  The local developer web interface.

  Two distinct interfaces on the same endpoint (port 4003):

  - **Human UI** (LiveView) — interactive browser pages at `/init`, `/setup`, `/tasks`
  - **LLM API** (Controllers) — markdown in/out at `/api/init`, `/api/setup`, `/api/tasks`

  LiveViews use `:live_view`. API controllers use `:controller`.
  Markdown rendering for the API lives in `*Markdown` modules.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.AgentHarness,
      # `cms harness` boots the light harness from this same application — see
      # `Application.start_harness/0`. One binary that can be either.
      CmsHarness,
      CodeMySpec.Environments,
      CodeMySpec.FileEdits,
      CodeMySpec.Hooks,
      CodeMySpec.McpServers,
      # Story LiveViews are shared with the cloud app and live there. The edge
      # only runs this way: CodeMySpecWeb reaches back through the
      # `:story_host` assign, never by naming this boundary.
      CodeMySpecWeb
    ],
    exports: :all

  def static_paths, do: ~w(local/assets)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :text]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      # Same component library the cloud app imports — see
      # `CodeMySpecWeb.core_components/0`. The terminal look comes from
      # `local_app.css` theming those components' classes, not from a
      # second copy of the components.
      import unquote(CodeMySpecWeb.core_components())
      import CodeMySpecWeb.Markdown, only: [md_html: 1]

      alias CodeMySpecLocalWeb.Layouts
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CodeMySpecLocalWeb.Endpoint,
        router: CodeMySpecLocalWeb.Router,
        statics: CodeMySpecLocalWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/html/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
