defmodule CodeMySpecWeb.RequirementsLive do
  @moduledoc """
  The requirements graph, drawn: every node and edge `GraphProjector`
  projects, with where the answer came from above it. Kept current by the
  graph writer's announcements and the file watcher.
  """
  use CodeMySpecWeb, :live_view

  require Logger

  # Coalesce a burst of file-watcher events into one graph recompute — the
  # trailing edge fires once the developer stops saving for this long.
  @graph_debounce_ms 750

  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.GraphReport
  alias CodeMySpecWeb.RequirementGraphComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :requirements,
       page_title: "Requirements graph",
       graph_data: nil,
       graph_provenance: nil,
       watching?: false,
       graph_timer: nil,
       selected: nil,
       requirements: nil,
       detail: %{},
       error: nil,
       setup_error: nil
     )}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{} = params, _uri, %{assigns: %{live_action: :graph}} = socket) do
    with_project(socket, fn project, scope ->
      socket = maybe_watch(socket, scope)

      base =
        assign(socket,
          project: project,
          focus: focus_key(project, params["focus"]),
          selected: focus_key(project, params["focus"]),
          error: nil,
          setup_error: nil
        )

      socket =
        if params["preload"] == "true" do
          {graph_data, metrics} = GraphProjector.project_graph_with_metrics(scope)
          apply_graph_result(base, graph_data, metrics)
        else
          base
          |> assign(graph_data: :loading)
          |> maybe_start_graph_compute(scope)
        end

      {:noreply, socket}
    end)
  end

  # A node clicked in the graph (`SigmaGraph` pushes its key here). The
  # requirements behind the nodes are read on the first pick and kept.
  @impl true
  def handle_event("select_node", %{"key" => key}, socket),
    do: {:noreply, socket |> assign(:selected, key) |> with_requirements() |> with_detail()}

  defp with_requirements(%{assigns: %{requirements: nil, current_scope: scope}} = socket)
       when not is_nil(scope) do
    {nodes, _computed_at} = Requirements.cached_all(scope)
    assign(socket, :requirements, Map.new(nodes, &{GraphProjector.key(&1), &1}))
  end

  defp with_requirements(socket), do: socket

  defp with_detail(%{assigns: %{selected: key, requirements: %{} = requirements}} = socket) do
    case requirements[key] do
      nil ->
        assign(socket, :detail, %{})

      node ->
        assign(
          socket,
          :detail,
          RequirementGraphComponents.detail(socket.assigns.current_scope, node)
        )
    end
  end

  defp with_detail(socket), do: socket

  # --- Async work ---

  @impl true
  def handle_async(:compute_graph, {:ok, {graph_data, metrics}}, socket) do
    {:noreply, apply_graph_result(socket, graph_data, metrics)}
  end

  def handle_async(:compute_graph, {:exit, reason}, socket) do
    Logger.error("[RequirementsLive] graph compute crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(graph_data: :error)
     |> push_event("graph:error", %{message: "Graph computation failed: #{inspect(reason)}"})}
  end

  # Watcher-triggered recompute pushes a merge update (NOT graph:ready), so the
  # client preserves existing node positions and only restyles/places what
  # actually changed.
  def handle_async(:recompute_graph, {:ok, {graph_data, _metrics}}, socket) do
    {:noreply,
     socket
     |> assign(graph_data: graph_data)
     |> push_event("graph:update", %{data: graph_data})}
  end

  def handle_async(:recompute_graph, {:exit, reason}, socket) do
    # Keep the last good graph on screen; just log the failed refresh.
    Logger.warning("[RequirementsLive] graph refresh crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # --- Live updates ---

  # A single-path sync fired for this project. Debounce on the trailing edge so a
  # burst of saves coalesces into a single recompute once edits settle.
  @impl true
  def handle_info({:watcher_synced, _info}, %{assigns: %{live_action: :graph}} = socket) do
    if ref = socket.assigns.graph_timer, do: Process.cancel_timer(ref)
    timer = Process.send_after(self(), :graph_recompute, @graph_debounce_ms)
    {:noreply, assign(socket, graph_timer: timer)}
  end

  def handle_info({:watcher_synced, _info}, socket), do: {:noreply, socket}

  # The event writer finished a pass. Only `IncrementalGraph` announces this,
  # and only when it is the graph's writer: a sync it consumed can rewire edges
  # without changing any node, and the page has to show that too.
  def handle_info({:graph_updated, project_id}, %{assigns: %{current_scope: scope}} = socket)
      when not is_nil(scope) do
    if project_id == scope.active_project_id,
      do: handle_info({:watcher_synced, %{}}, socket),
      else: {:noreply, socket}
  end

  def handle_info(
        {event, %CodeMySpec.Issues.Issue{project_id: project_id}},
        %{assigns: %{live_action: :graph, current_scope: scope}} = socket
      )
      when event in [:created, :updated, :accepted, :resolved, :dismissed, :deleted] do
    if project_id == scope.active_project_id,
      do: handle_info({:watcher_synced, %{}}, socket),
      else: {:noreply, socket}
  end

  def handle_info(:graph_recompute, %{assigns: %{current_scope: scope}} = socket)
      when not is_nil(scope) do
    socket = assign(socket, graph_timer: nil)

    # Only refresh once the graph has actually rendered (is_map); a delta
    # update has nothing to merge into before the first full render.
    socket =
      if connected?(socket) and is_map(socket.assigns.graph_data) do
        start_async(socket, :recompute_graph, fn ->
          GraphProjector.project_graph_with_metrics(scope)
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:graph_recompute, socket), do: {:noreply, assign(socket, graph_timer: nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Subscribe once to this project's watcher topic (idempotent across repeated
  # handle_params on the :graph action).
  defp maybe_watch(%{assigns: %{watching?: true}} = socket, _scope), do: socket

  defp maybe_watch(socket, scope) do
    if connected?(socket) do
      ProjectSync.subscribe(scope)
      CodeMySpec.Issues.subscribe(scope)
      if scope.active_project_id, do: GraphInputs.subscribe(scope.active_project_id)
      assign(socket, watching?: true)
    else
      socket
    end
  end

  defp maybe_start_graph_compute(socket, scope) do
    if connected?(socket) do
      start_async(socket, :compute_graph, fn ->
        GraphProjector.project_graph_with_metrics(scope)
      end)
    else
      socket
    end
  end

  defp apply_graph_result(socket, graph_data, metrics) do
    Logger.info("[RequirementsLive] graph computed: #{inspect(metrics)}")

    socket
    |> assign(graph_data: graph_data)
    |> then(&if(&1.assigns.selected, do: &1 |> with_requirements() |> with_detail(), else: &1))
    |> assign(graph_provenance: provenance(metrics, socket.assigns.current_scope))
    |> push_event("graph:ready", %{data: graph_data, metrics: metrics})
  end

  # Where this answer came from, for the strip above the graph.
  #
  # The page recomputed the whole graph on every visit until 2026-09-11, so it
  # had nothing to say here — no cached answer to be fresh or stale. That made
  # the one property stories 1062 and 1063 are about invisible on the one page
  # people open to look at the graph, and QA on 1063 was blocked looking for it.
  #
  # The watcher's state belongs beside it because the two failures look
  # identical from outside: a graph that has not changed and a graph that has
  # stopped being able to change both show an unmoving `computed_at`.
  # `last_error` is the only thing that tells them apart.
  defp provenance(metrics, scope) do
    %{
      computed_at: metrics[:computed_at],
      served_from: metrics[:served_from],
      node_count: metrics[:node_count],
      project_issue_count: metrics[:project_issue_count] || 0,
      writer: GraphReport.writer_name(),
      watcher: scope && GraphReport.writer_status(scope.active_project_id)
    }
  end

  # --- Render ---

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

      <div :if={@setup_error} data-role="setup-error" role="alert" class="alert alert-error my-4">
        <span>Setup error: {@setup_error}</span>
      </div>

      <.graph_view
        :if={@graph_data}
        project={@project}
        graph_data={@graph_data}
        provenance={@graph_provenance}
        focus={assigns[:focus]}
        selected={@selected}
        requirements={@requirements}
        detail={@detail}
      />
    </Layouts.app>
    """
  end

  # --- Page components ---

  attr :project, :map, required: true
  attr :graph_data, :any, required: true

  attr :provenance, :any, default: nil
  attr :focus, :string, default: nil
  attr :selected, :string, default: nil
  attr :requirements, :map, default: nil
  attr :detail, :map, default: %{}

  defp graph_view(assigns) do
    ~H"""
    <div id="graph-page">
      <div class="mb-4 flex items-center justify-between gap-3">
        <h1 class="text-2xl font-bold">Requirements Graph</h1>
        <%!-- The hook puts its "Copy graph debug" action here. --%>
        <div id="sigma-graph-debug"></div>
      </div>
      <.graph_provenance :if={@provenance} provenance={@provenance} />
      <RequirementGraphComponents.legend />
      <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_22rem]">
        <div
          id="sigma-graph"
          phx-hook="SigmaGraph"
          data-graph={if is_map(@graph_data), do: Jason.encode!(@graph_data)}
          data-focus={@focus}
          data-select-target="#graph-page"
          phx-update="ignore"
          class="rounded-box border border-base-300 bg-base-200"
          style="position: relative; overflow: hidden; width: 100%; height: 80vh;"
        >
        </div>
        <div class="rounded-box border border-base-300 p-3 lg:h-[80vh] lg:overflow-y-auto">
          <RequirementGraphComponents.node_detail
            node={@selected && @requirements && @requirements[@selected]}
            edges={if is_map(@graph_data), do: @graph_data.edges, else: []}
            requirements={@requirements || %{}}
            extra={@detail}
            target={nil}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :provenance, :map, required: true

  # Where this answer came from, and whether the thing that keeps it current is
  # still working.
  #
  # Two failures look identical without this. A graph that has not changed and a
  # graph that has stopped being able to change both show an unmoving
  # `computed_at`; only the watcher's `last_error` separates them, and the second
  # is the worse one — every reader keeps being served the last good answer,
  # which looks right and never moves again.
  defp graph_provenance(assigns) do
    ~H"""
    <div
      data-test="graph-provenance"
      data-served-from={@provenance.served_from}
      class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/60 mb-4"
    >
      <span>
        {@provenance.node_count} requirements,
        <span data-test="graph-served-from">
          {if @provenance.served_from == "cache", do: "from cache", else: "not computed yet"}
        </span>
      </span>
      <span data-test="graph-project-issues">
        + {@provenance.project_issue_count} live project issue branches: assigned → submitted → completed
      </span>
      <span data-test="graph-computed-at" title={@provenance.computed_at}>
        nodes last checked {@provenance.computed_at}
      </span>
      <span
        :if={@provenance.watcher && @provenance.watcher.last_recompute}
        data-test="graph-last-pass"
        title={@provenance.watcher.last_recompute}
      >
        {@provenance.writer} last ran {@provenance.watcher.last_recompute}
      </span>
      <span :if={@provenance.watcher} data-test="graph-watcher">
        {@provenance.writer} {if @provenance.watcher.pending,
          do: "has a pass pending",
          else: "idle"}
      </span>
      <span :if={is_nil(@provenance.watcher)} data-test="graph-watcher" class="text-warning">
        no {@provenance.writer} — this graph only moves when somebody reads it
      </span>
      <span
        :if={@provenance.watcher && @provenance.watcher.last_error}
        data-test="graph-watcher-error"
        class="text-error font-medium"
      >
        last recompute failed: {@provenance.watcher.last_error.message}
      </span>
    </div>
    """
  end

  # A project gate's node key, as `GraphProjector` writes it, for `?focus=`.
  defp focus_key(_project, nil), do: nil
  defp focus_key(project, name), do: "project_#{String.replace(project.id, "-", "")}_#{name}"

  defp with_project(%{assigns: %{current_scope: %{} = scope, project: project}} = _socket, fun),
    do: fun.(project, scope)
end
