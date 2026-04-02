defmodule CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureGraph do
  @moduledoc """
  Returns the Mermaid dependency graph showing contexts, liveviews, and their relationships.

  Dependencies are rolled up from child components to parent contexts.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame) do
      components = Components.list_components_with_dependencies(scope)
      mermaid = Architecture.generate_dependency_graph(components)

      {:reply, text_response(mermaid), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end
end
