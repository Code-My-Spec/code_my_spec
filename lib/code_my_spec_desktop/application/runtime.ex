defmodule CodeMySpecDesktop.Application.Runtime do
  @moduledoc "Starts the SQLite database, web application and local harness."

  alias CodeMySpec.Integrations.DesktopClients
  alias CodeMySpecDesktop.FirstBoot

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  def start_link(_opts) do
    FirstBoot.ensure_database()
    DesktopClients.configure()
    CodeMySpecWeb.Application.start(:normal, children: &children/1)
  end

  def children(web_children) do
    Enum.flat_map(web_children, fn
      {Phoenix.PubSub, _} = pubsub ->
        [pubsub, FirstBoot]

      {CodeMySpec.McpServers.LocalServer, opts} ->
        [
          {CodeMySpec.McpServers.LocalServer,
           Keyword.put(opts, :transport, {:streamable_http, start: true})}
        ]

      # CmsHarness.Supervisor starts its own, and the name is global.
      CodeMySpec.RunGuard ->
        []

      child ->
        [child]
    end) ++ [CmsHarness.Supervisor]
  end
end
