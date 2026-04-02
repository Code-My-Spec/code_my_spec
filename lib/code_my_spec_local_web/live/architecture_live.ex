defmodule CodeMySpecLocalWeb.ArchitectureLive do
  @moduledoc """
  Displays architecture views: mermaid dependency graph and component overview.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, project: nil, mermaid: nil, overview: nil, namespace: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      components = Components.list_components_with_dependencies(scope)
      mermaid = Architecture.generate_dependency_graph(components)
      overview = Architecture.generate_overview(components)
      namespace = Architecture.generate_namespace_hierarchy(components)

      {:noreply,
       assign(socket,
         project: project,
         slug: project_slug(project),
         mermaid: mermaid,
         overview: overview,
         namespace: namespace,
         page_title: "Architecture — #{project.name}",
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} role="alert" class="alert alert-error">
      <span>{@error}</span>
    </div>

    <div :if={!@error && @project}>
      <div class="mb-4">
        <.link navigate={"/projects/#{@slug}"} class="text-blue-400 hover:underline">
          ← Back to project
        </.link>
      </div>

      <h1 class="text-2xl font-bold mb-6">Architecture</h1>

      <div class="mb-8">
        <h2 class="text-xl font-semibold mb-4">Dependency Graph</h2>
        <div id="mermaid-graph" phx-hook="Mermaid" data-graph={@mermaid} phx-update="ignore">
          <pre class="mermaid">{@mermaid}</pre>
        </div>
      </div>

      <div class="mb-8">
        <h2 class="text-xl font-semibold mb-4">Component Overview</h2>
        <div class="prose prose-invert max-w-none">
          {raw(CodeMySpecLocalWeb.markdown_to_html(@overview))}
        </div>
      </div>

      <div class="mb-8">
        <h2 class="text-xl font-semibold mb-4">Namespace Hierarchy</h2>
        <pre class="bg-base-200 p-4 rounded-lg overflow-x-auto text-sm">{@namespace}</pre>
      </div>
    </div>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
