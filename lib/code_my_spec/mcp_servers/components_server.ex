defmodule CodeMySpec.McpServers.ComponentsServer do
  @moduledoc false
  use Anubis.Server,
    name: "components-server",
    version: "1.0.0",
    capabilities: [:tools]

  # Core CRUD operations
  component(CodeMySpec.McpServers.Components.Tools.CreateComponent)
  component(CodeMySpec.McpServers.Components.Tools.UpdateComponent)
  component(CodeMySpec.McpServers.Components.Tools.DeleteComponent)
  component(CodeMySpec.McpServers.Components.Tools.GetComponent)
  component(CodeMySpec.McpServers.Components.Tools.ListComponents)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)

  # Batch operations
  # component(CodeMySpec.McpServers.Components.Tools.CreateComponents)
  # component(CodeMySpec.McpServers.Components.Tools.CreateDependencies)

  # Dependency management
  component(CodeMySpec.McpServers.Components.Tools.CreateDependency)
  component(CodeMySpec.McpServers.Components.Tools.DeleteDependency)

  # Architecture and design tools
  component(CodeMySpec.McpServers.Components.Tools.StartContextDesign)
  component(CodeMySpec.McpServers.Components.Tools.ReviewContextDesign)
  component(CodeMySpec.McpServers.Components.Tools.ShowArchitecture)
  component(CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummary)
  component(CodeMySpec.McpServers.Components.Tools.ContextStatistics)
  component(CodeMySpec.McpServers.Components.Tools.OrphanedContexts)
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
end
