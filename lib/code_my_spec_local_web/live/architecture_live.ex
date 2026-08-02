defmodule CodeMySpecLocalWeb.ArchitectureLive do
  @moduledoc """
  Architecture views: dependency graph, component overview, and namespace
  hierarchy. Each view is a separate live_action, navigated via tabs.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.GraphProjector
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
      view = compute_view(socket.assigns.live_action, scope)

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

  defp compute_view(:dependency_graph, scope),
    do: {:dependency_graph, GraphProjector.components_graph(scope)}

  defp compute_view(:overview, scope),
    do: {:overview, Architecture.generate_overview(Components.list_components_with_dependencies(scope))}

  defp compute_view(:namespaces, scope),
    do: {:namespaces, Architecture.generate_namespace_hierarchy(Components.list_components_with_dependencies(scope))}

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
            patch={~p"/app/projects/#{@slug}/architecture"}
            role="tab"
            class={["tab", @live_action == :dependency_graph && "tab-active"]}
          >
            Dependency Graph
          </.link>
          <.link
            patch={~p"/app/projects/#{@slug}/architecture/overview"}
            role="tab"
            class={["tab", @live_action == :overview && "tab-active"]}
          >
            Component Overview
          </.link>
          <.link
            patch={~p"/app/projects/#{@slug}/architecture/namespaces"}
            role="tab"
            class={["tab", @live_action == :namespaces && "tab-active"]}
          >
            Namespace Hierarchy
          </.link>
        </div>

        <div :if={match?({:dependency_graph, _}, @view)}>
          <div class="flex flex-wrap gap-4 text-sm mb-4">
            <span class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-primary inline-block"></span> Satisfied
            </span>
            <span class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-success inline-block"></span> Actionable
            </span>
            <span class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-warning inline-block"></span> Blocked
            </span>
          </div>
          <div
            id="sigma-graph"
            phx-hook="SigmaGraph"
            data-graph={Jason.encode!(elem(@view, 1))}
            phx-update="ignore"
            class="rounded-box border border-base-300 bg-base-200"
            style="width: 100%; height: 80vh;"
          >
          </div>
        </div>

        <div :if={match?({:overview, _}, @view)}>
          <div class="prose prose-sm md:prose-base max-w-none bg-base-200 border border-base-300 rounded-box p-6 overflow-x-auto">
            {md_html(elem(@view, 1))}
          </div>
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
