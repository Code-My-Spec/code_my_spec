defmodule CodeMySpecDesktop.Application do
  @moduledoc "Starts the desktop runtime and opens model onboarding under /app."

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Application,
      CodeMySpec.Integrations,
      CodeMySpec.McpServers,
      CodeMySpec.Utils,
      CodeMySpecDesktop,
      CodeMySpecWeb
    ]

  use Application

  alias CodeMySpec.Utils.Browser
  alias CodeMySpecDesktop.Application.Shell

  @impl true
  def start(_type, _args) do
    CmsHarness.Application.prepare_host()

    Shell.start_link(
      view: &view/1,
      app_url: Application.fetch_env!(:code_my_spec, :base_url) <> "/app"
    )
  end

  # The native window; `CMS_BROWSER` falls back to opening the default browser.
  # Closing hides it (John): the server and harness keep serving hooks, and the
  # menu-bar icon reopens or quits.
  def view(url) do
    if System.get_env("CMS_BROWSER") in [nil, ""] do
      {Desktop.Window,
       app: :code_my_spec,
       id: CodeMySpecWindow,
       title: "CodeMySpec",
       size: {1280, 860},
       min_size: {900, 600},
       icon: "static/images/logo-300.png",
       icon_menu: CodeMySpecDesktop.Menu,
       on_close: :hide,
       url: fn -> url end}
    else
      {Browser, url}
    end
  end
end
