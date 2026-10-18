defmodule CodeMySpec.McpServers.ComponentsServer do
  @moduledoc false
  alias Anubis.Server.Handlers
  alias CodeMySpec.McpServers.LibraryTools
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.ToolLibrary

  use Anubis.Server,
    name: "components-server",
    version: "1.0.0",
    capabilities: [:tools]

  # Story arguments are normalised before validation, as on `LocalServer`.
  @impl Anubis.Server
  def handle_request(%{"method" => "tools/call"} = request, frame) do
    request |> StoryRefs.normalize_request(registrations()) |> Handlers.handle(__MODULE__, frame)
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  # The component tools are library tools (`CodeMySpec.Components.Tools`),
  # registered on each session's frame at `init/2`, as on `LocalServer`.
  @library_tools ~w(create_component update_component delete_component add_dependency
                    remove_dependency get_component list_components start_context_design
                    review_context_design show_architecture architecture_health_summary
                    context_statistics orphaned_contexts)

  @doc "The library tools this server lists."
  def library_tools, do: Enum.filter(ToolLibrary.tools(), &(&1.name() in @library_tools))

  @doc "Every tool on this server: the components, then its library tools."
  def registrations,
    do: __components__() ++ Enum.map(library_tools(), &ToolLibrary.registration/1)

  @impl Anubis.Server
  def init(_client_info, frame), do: {:ok, LibraryTools.register(frame, library_tools())}

  @impl Anubis.Server
  def handle_tool_call(name, params, frame),
    do: LibraryTools.call(library_tools(), name, params, frame)

  # Core CRUD operations
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent)

  # Dependency edges are derived from spec files — the architect edits
  # the source component's `## Dependencies` section and ComponentSync
  # writes the graph rows. No CRUD tool surface for dependencies.

  # Architecture and design tools
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
end
