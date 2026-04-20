defmodule CodeMySpecLocalWeb.ArchitectureLive do
  @moduledoc """
  Architecture views: dependency graph, component overview, and namespace
  hierarchy. Each view is a separate live_action, navigated via tabs.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, slug: nil, view: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      components = Components.list_components_with_dependencies(scope)
      view = compute_view(socket.assigns.live_action, components)

      {:noreply,
       assign(socket,
         project: project,
         slug: project_slug(project),
         view: view,
         page_title: "#{project.name} — Architecture",
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  defp compute_view(:dependency_graph, components),
    do: {:dependency_graph, Architecture.generate_dependency_graph(components)}

  defp compute_view(:overview, components),
    do: {:overview, Architecture.generate_overview(components)}

  defp compute_view(:namespaces, components),
    do: {:namespaces, Architecture.generate_namespace_hierarchy(components)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:architecture}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">Architecture</h1>
          <p class="text-base-content/60 mt-1">Structural views of the project's components.</p>
        </div>

        <div role="tablist" class="tabs tabs-bordered mb-6">
          <.link
            patch={~p"/projects/#{@slug}/architecture"}
            role="tab"
            class={["tab", @live_action == :dependency_graph && "tab-active"]}
          >
            Dependency Graph
          </.link>
          <.link
            patch={~p"/projects/#{@slug}/architecture/overview"}
            role="tab"
            class={["tab", @live_action == :overview && "tab-active"]}
          >
            Component Overview
          </.link>
          <.link
            patch={~p"/projects/#{@slug}/architecture/namespaces"}
            role="tab"
            class={["tab", @live_action == :namespaces && "tab-active"]}
          >
            Namespace Hierarchy
          </.link>
        </div>

        <div :if={match?({:dependency_graph, _}, @view)}>
          <div
            id="mermaid-graph"
            phx-hook="Mermaid"
            data-graph={elem(@view, 1)}
            phx-update="ignore"
            class="bg-base-200 border border-base-300 rounded-box p-4"
          >
            <pre class="mermaid">{elem(@view, 1)}</pre>
          </div>
        </div>

        <div :if={match?({:overview, _}, @view)}>
          <article class="prose max-w-none bg-base-200 border border-base-300 rounded-box p-6">
            {raw(CodeMySpecLocalWeb.markdown_to_html(elem(@view, 1)))}
          </article>
        </div>

        <div :if={match?({:namespaces, _}, @view)}>
          <pre class="bg-base-200 border border-base-300 rounded-box p-4 overflow-x-auto text-sm">{elem(@view, 1)}</pre>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
