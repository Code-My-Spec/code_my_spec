defmodule CodeMySpecWeb.ArchitectureLive do
  @moduledoc """
  Architecture views: the boundary graph and the namespace hierarchy. Each
  view is a separate live_action, navigated via tabs.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Architecture
  alias CodeMySpec.Architecture.BoundaryGraph
  alias CodeMySpec.Components
  alias CodeMySpecWeb.ArchitectureComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :architecture,
       page_title: "Architecture",
       view: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(
        _params,
        _uri,
        %{assigns: %{current_scope: %{} = scope, project: project}} = socket
      ) do
    view = compute_view(socket.assigns.live_action, scope)

    {:noreply,
     assign(socket,
       view: view,
       page_title: "#{project.name} — Architecture",
       error: nil
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp compute_view(:dependency_graph, scope),
    do: {:dependency_graph, BoundaryGraph.build(scope)}

  defp compute_view(:namespaces, scope),
    do:
      {:namespaces,
       Architecture.generate_namespace_hierarchy(
         Components.list_components_with_dependencies(scope)
       )}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={@project}
      projects={@projects}
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
            patch={~p"/app/projects/#{@project.id}/architecture"}
            role="tab"
            class={["tab", @live_action == :dependency_graph && "tab-active"]}
          >
            Boundaries
          </.link>
          <.link
            patch={~p"/app/projects/#{@project.id}/architecture/namespaces"}
            role="tab"
            class={["tab", @live_action == :namespaces && "tab-active"]}
          >
            Namespace Hierarchy
          </.link>
        </div>

        <div :if={match?({:dependency_graph, _}, @view)}>
          <ArchitectureComponents.summary summary={elem(@view, 1).summary} />
          <p class="text-sm text-base-content/60 mt-4 mb-2">
            ⌘/Ctrl-scroll or pinch to zoom; drag, or two fingers on a phone, to pan.
          </p>
          <ArchitectureComponents.graph id="sigma-graph" graph={elem(@view, 1)} />
        </div>

        <div :if={match?({:namespaces, _}, @view)}>
          <pre class="bg-base-200 border border-base-300 rounded-box p-4 overflow-x-auto text-sm">{elem(@view, 1)}</pre>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
