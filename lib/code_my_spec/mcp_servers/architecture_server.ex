defmodule CodeMySpec.McpServers.ArchitectureServer do
  @moduledoc "MCP server exposing architecture management tools to AI agents."

  use Anubis.Server,
    name: "architecture-server",
    version: "1.0.0",
    capabilities: [:tools]

  alias Anubis.Server.Frame

  @impl true
  def init(_client_info, frame) do
    scope = frame.assigns[:current_scope] || resolve_scope()
    {:ok, Frame.assign(frame, :current_scope, scope)}
  end

  defp resolve_scope do
    case Application.get_env(:code_my_spec, :scope_resolver) do
      resolver when is_function(resolver, 0) -> resolver.()
      _ -> nil
    end
  end

  # Architecture analysis
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph)
  component(CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories)
end
