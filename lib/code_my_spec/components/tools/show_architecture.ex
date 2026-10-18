defmodule CodeMySpec.Components.Tools.ShowArchitecture do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "show_architecture"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        components = Components.list_components_with_dependencies(scope)
        mermaid = Architecture.generate_mermaid(components)

        {:ok, mermaid}

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  end
end
