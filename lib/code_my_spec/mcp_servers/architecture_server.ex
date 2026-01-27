defmodule CodeMySpec.McpServers.ArchitectureServer do
  use Hermes.Server,
    name: "architecture-server",
    version: "1.0.0",
    capabilities: [:tools]

  alias Hermes.Server.Frame

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

  # Spec file management
  component(CodeMySpec.McpServers.Architecture.Tools.CreateSpec)
  component(CodeMySpec.McpServers.Architecture.Tools.UpdateSpecMetadata)
  component(CodeMySpec.McpServers.Architecture.Tools.ListSpecs)
  component(CodeMySpec.McpServers.Architecture.Tools.ListSpecNames)
  component(CodeMySpec.McpServers.Architecture.Tools.GetSpec)
  component(CodeMySpec.McpServers.Architecture.Tools.DeleteSpec)

  # Design workflow tools replaced by skills:
  # - /design-architecture replaces StartArchitectureDesign
  # - /review-architecture replaces ReviewArchitectureDesign

  # Architecture analysis
  # component(CodeMySpec.McpServers.Architecture.Tools.GetArchitectureSummary)
  # component(CodeMySpec.McpServers.Architecture.Tools.GetComponentImpact)
  component(CodeMySpec.McpServers.Architecture.Tools.GetComponentView)
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph)

  # Greenfield architecture design tools
  component(CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories)
  component(CodeMySpec.McpServers.Architecture.Tools.ProposeArchitecture)
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateProposal)
  component(CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal)
  component(CodeMySpec.McpServers.Architecture.Tools.CreateContextWithChildren)
end
