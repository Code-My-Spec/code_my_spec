defmodule CodeMySpecDesktop.Application.Runtime do
  @moduledoc "Starts database-dependent desktop services after prerequisite setup."

  alias CodeMySpec.Integrations.DesktopClients
  alias CodeMySpecDesktop.FirstBoot

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary,
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

      child ->
        [child]
    end) ++ [CmsHarness.Supervisor]
  end
end
