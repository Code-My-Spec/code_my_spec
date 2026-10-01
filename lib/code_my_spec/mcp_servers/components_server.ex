defmodule CodeMySpec.McpServers.ComponentsServer do
  @moduledoc false
  alias Anubis.Server.Handlers
  alias CodeMySpec.McpServers.StoryRefs

  use Anubis.Server,
    name: "components-server",
    version: "1.0.0",
    capabilities: [:tools]

  # Story arguments are normalised before validation, as on `LocalServer`.
  @impl Anubis.Server
  def handle_request(%{"method" => "tools/call"} = request, frame) do
    request |> StoryRefs.normalize_request(__components__()) |> Handlers.handle(__MODULE__, frame)
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  # Core CRUD operations
  component(CodeMySpec.McpServers.Components.Tools.CreateComponent)
  component(CodeMySpec.McpServers.Components.Tools.UpdateComponent)
  component(CodeMySpec.McpServers.Components.Tools.DeleteComponent)
  component(CodeMySpec.McpServers.Components.Tools.AddDependency)
  component(CodeMySpec.McpServers.Components.Tools.RemoveDependency)
  component(CodeMySpec.McpServers.Components.Tools.GetComponent)
  component(CodeMySpec.McpServers.Components.Tools.ListComponents)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent)

  # Dependency edges are derived from spec files — the architect edits
  # the source component's `## Dependencies` section and ComponentSync
  # writes the graph rows. No CRUD tool surface for dependencies.

  # Architecture and design tools
  component(CodeMySpec.McpServers.Components.Tools.StartContextDesign)
  component(CodeMySpec.McpServers.Components.Tools.ReviewContextDesign)
  component(CodeMySpec.McpServers.Components.Tools.ShowArchitecture)
  component(CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummary)
  component(CodeMySpec.McpServers.Components.Tools.ContextStatistics)
  component(CodeMySpec.McpServers.Components.Tools.OrphanedContexts)
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
end
