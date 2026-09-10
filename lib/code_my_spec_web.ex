defmodule CodeMySpecWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use CodeMySpecWeb, :controller
      use CodeMySpecWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.Accounts,
      # The harness channel records the turns a sprite reports. `AgentHarness`
      # is top-level for the same reason `Hooks` is — it reaches McpServers.
      CodeMySpec.AgentHarness,
      CodeMySpec.Analytics,
      CodeMySpec.AppTokens,
      CodeMySpec.Authorization,
      CodeMySpec.Billing,
      CodeMySpec.BootVersion,
      CodeMySpec.CmsUsers,
      CodeMySpec.Content,
      CodeMySpec.ContentPublishing,
      CodeMySpec.Environments,
      CodeMySpec.Events,
      CodeMySpec.ExternalUsers,
      # The harness channel decides hooks. `Hooks` is its own top-level boundary
      # rather than domain code because the stop decision reaches into
      # McpServers, which `CodeMySpec` deliberately does not depend on.
      CodeMySpec.Hooks,
      CodeMySpec.Integrations,
      CodeMySpec.Invitations,
      CodeMySpec.Knowledge,
      CodeMySpec.Logging,
      CodeMySpec.Mail,
      CodeMySpec.McpServers,
      CodeMySpec.Oauth,
      CodeMySpec.Projects,
      CodeMySpec.ProjectSecrets,
      CodeMySpec.ProjectUsers,
      CodeMySpec.ScreenState,
      CodeMySpec.Uploads,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  # `vendor` holds script-tag libraries (graphology, sigma) rather than build
  # output. They cannot live under `assets`: that directory is esbuild's outdir
  # and is gitignored, so anything placed there is absent in production.
  def static_paths,
    do:
      ~w(assets vendor fonts images favicon.ico robots.txt sw.js manifest.json 2b3072f808084089a59fa6ee3a6555b3.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: CodeMySpecWeb.Gettext

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

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  @doc """
  The component library this build imports as `<.button>`, `<.header>`, and
  friends.

  Both web apps share one component vocabulary; what differs between them is
  CSS, not markup, so the default serves the local terminal zone and the cloud
  zone equally well. The seam is here for when that stops being true — point
  `:core_components` at another module and this build's views pick it up, with
  no LiveView changes. A replacement must cover the same surface, since every
  `use CodeMySpecWeb, :html` caller imports it.
  """
  @core_components Application.compile_env(
                     :code_my_spec,
                     :core_components,
                     CodeMySpecWeb.CoreComponents
                   )

  def core_components, do: @core_components

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: CodeMySpecWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components — see `CodeMySpecWeb.core_components/0`
      import unquote(core_components())
      # Marketing-zone components (eyebrow, install_card)
      import CodeMySpecWeb.MarketingComponents
      # Markdown rendering for agent prompts and on-disk docs — shared, because
      # the views that render them are.
      import CodeMySpecWeb.Markdown, only: [md_html: 1]

      # Common modules used in templates
      alias CodeMySpecWeb.ExternalLinks
      alias CodeMySpecWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CodeMySpecWeb.Endpoint,
        router: CodeMySpecWeb.Router,
        statics: CodeMySpecWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
