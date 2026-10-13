defmodule CodeMySpecWeb.ArchitectureLive do
  @moduledoc """
  Architecture views: the boundary graph and the namespace hierarchy. Each
  view is a separate live_action, navigated via tabs.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Architecture
  alias CodeMySpec.Architecture.BoundaryGraph
  alias CodeMySpec.Components

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
  def handle_params(_params, _uri, %{assigns: %{scope: %{} = scope, project: project}} = socket) do
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
          patch={path(@socket, ~p"/app/projects/#{@slug}/architecture")}
          role="tab"
          class={["tab", @live_action == :dependency_graph && "tab-active"]}
        >
          Boundaries
        </.link>
        <.link
          patch={path(@socket, ~p"/app/projects/#{@slug}/architecture/namespaces")}
          role="tab"
          class={["tab", @live_action == :namespaces && "tab-active"]}
        >
          Namespace Hierarchy
        </.link>
      </div>

      <div :if={match?({:dependency_graph, _}, @view)}>
        <.boundary_summary summary={elem(@view, 1).summary} />
        <p class="text-sm text-base-content/60 mb-2">
          ⌘/Ctrl-scroll or pinch to zoom; drag, or two fingers on a phone, to pan.
        </p>
        <div
          id="sigma-graph"
          phx-hook="SigmaGraph"
          data-graph={Jason.encode!(Map.delete(elem(@view, 1), :summary))}
          phx-update="ignore"
          class="rounded-box border border-base-300 bg-base-200"
          style="position: relative; overflow: hidden; width: 100%; height: 80vh;"
        >
        </div>
        <div id="sigma-graph-debug" phx-update="ignore"></div>
      </div>

      <div :if={match?({:namespaces, _}, @view)}>
        <pre class="bg-base-200 border border-base-300 rounded-box p-4 overflow-x-auto text-sm">{elem(@view, 1)}</pre>
      </div>
    </div>
    """
  end

  attr :summary, :map, required: true

  # The claims the graph makes, stated so they can be checked against it.
  defp boundary_summary(assigns) do
    ~H"""
    <div data-test="boundary-summary" class="text-sm text-base-content/70 mb-4 space-y-1">
      <p :if={!@summary.declarations_recorded} class="text-warning">
        No `use Boundary` declarations recorded yet — they arrive with the next full scan.
      </p>
      <p>
        <span data-test="boundary-count">{@summary.boundaries} boundaries</span>, <span data-test="boundary-edges">{@summary.edges} dependencies between them</span>,
        <span data-test="boundary-depth">{@summary.depth} deep</span>
        <span :if={@summary.unowned_modules > 0}>
          · {@summary.unowned_modules} modules under no boundary
        </span>
      </p>
      <p :if={@summary.longest_chain != []} data-test="boundary-longest-chain" class="break-words">
        Longest chain: {Enum.join(@summary.longest_chain, " → ")}
      </p>
      <p :if={@summary.cycles == []} data-test="boundary-cycles">No cycles.</p>
      <div :if={@summary.cycles != []} data-test="boundary-cycles" class="text-error">
        {length(@summary.cycles)} cycle(s), drawn in red:
        <ul class="list-disc ml-5">
          <li :for={cycle <- @summary.cycles}>{Enum.join(cycle, " ↔ ")}</li>
        </ul>
      </div>
    </div>
    """
  end
end
