defmodule CodeMySpecDesktop.Application do
  @moduledoc """
  The desktop env's `mod` (bb8bc042). The web application's tree with the
  desktop's children added: FirstBoot after PubSub and before anything reads
  the database, then the harness after the Endpoint it talks to, then the
  native window (or, with `CMS_BROWSER`, the default browser). The host setup a harness needs under a service supervisor (PATH,
  `~/.codemyspec`, harness.log) and creating the database run before the tree.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CodeMySpec.Integrations,
      CodeMySpec.Utils,
      CodeMySpecDesktop,
      CodeMySpecWeb
    ]

  use Application

  alias CodeMySpec.Integrations.DesktopClients
  alias CodeMySpec.Utils.Browser
  alias CodeMySpecDesktop.FirstBoot

  @impl true
  def start(type, _args) do
    CmsHarness.Application.prepare_host()
    FirstBoot.ensure_database()
    DesktopClients.configure()
    CodeMySpecWeb.Application.start(type, children: &children/1)
  end

  def children(web_children) do
    Enum.flat_map(web_children, fn
      {Phoenix.PubSub, _} = pubsub -> [pubsub, FirstBoot, CodeMySpec.Integrations.OAuthHandoff]
      child -> [child]
    end) ++
      [CmsHarness.Supervisor, view(Application.fetch_env!(:code_my_spec, :base_url) <> "/app")]
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
