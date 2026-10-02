defmodule CodeMySpecDesktop.Application do
  @moduledoc """
  The desktop env's `mod` (bb8bc042). The web application's tree with the
  desktop's children added: FirstBoot after PubSub and before anything reads
  the database, then the harness after the Endpoint it talks to, then the
  browser. The host setup a harness needs under a service supervisor (PATH,
  `~/.codemyspec`, harness.log) and creating the database run before the tree.
  """

  use Boundary,
    top_level?: true,
    deps: [CmsHarness, CodeMySpecDesktop, CodeMySpecLocalWeb, CodeMySpecWeb]

  use Application

  alias CodeMySpecDesktop.Browser
  alias CodeMySpecDesktop.FirstBoot

  @impl true
  def start(type, _args) do
    CodeMySpecLocalWeb.Application.prepare_host()
    FirstBoot.ensure_database()
    CodeMySpecWeb.Application.start(type, children: &children/1)
  end

  def children(web_children) do
    Enum.flat_map(web_children, fn
      {Phoenix.PubSub, _} = pubsub -> [pubsub, FirstBoot]
      child -> [child]
    end) ++
      [CmsHarness.Supervisor, {Browser, Application.fetch_env!(:code_my_spec, :base_url)}]
  end
end
