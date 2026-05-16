defmodule CodeMySpec.McpServers.Components.Tools.ShowArchitecture do
  @moduledoc """
  Renders the project's component dependency graph as a Mermaid flowchart.

  Returns plain text — a `flowchart TD` followed by node and edge lines for
  every context, liveview, live_context, controller, and channel in the
  project. Dependencies declared on child components are rolled up to the
  containing surface, so the graph stays at the architecture level the
  architect cares about, not raw module-to-module.

  Mermaid was picked over JSON for two reasons: it's far less verbose for
  the same information, and it renders directly in any markdown-aware
  reader the agent or human is using.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        components = Components.list_components_with_dependencies(scope)
        mermaid = Architecture.generate_mermaid(components)

        {:reply,
         Anubis.Server.Response.tool()
         |> Anubis.Server.Response.text(mermaid), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end
end
