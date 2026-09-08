defmodule CodeMySpecWeb.RequirementsLive do
  @moduledoc """
  Human interface for the requirements graph.

  All data comes through the `Requirements` context which computes
  nodes on the fly from Files + Problems. The graph view uses
  `GraphProjector` for Mermaid rendering. Pages render the computed
  data directly as HTML — no intermediate markdown.
  """
  use CodeMySpecWeb, :live_view

  require Logger

  # Coalesce a burst of file-watcher events into one graph recompute — the
  # trailing edge fires once the developer stops saving for this long.
  @graph_debounce_ms 750

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Components
  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :requirements,
       page_title: "Requirements",
       page: nil,
       graph_data: nil,
       watching?: false,
       graph_timer: nil,
       error: nil,
       setup_error: nil
     )}
  end

  # --- Handle params ---

  @impl true
  def handle_params(%{"name" => req_name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    with_project(socket, fn project, scope ->
      handle_show_for_project(project, scope, req_name, socket)
    end)
  end

  def handle_params(
        %{"story_id" => story_id, "name" => req_name},
        _uri,
        %{assigns: %{live_action: :story_req_show}} = socket
      ) do
    with_project(socket, fn project, scope ->
      story = Stories.get_story!(scope, story_id)
      slug = socket.assigns.slug
      node = find_entity_node(scope, "story", story.id, req_name)

      if node do
        page = %{
          kind: :requirement,
          node: node,
          back: %{
            label: "← Back to #{story.title}",
            to: "/app/projects/#{slug}/stories/#{story_id}"
          },
          prereqs: [],
          dependents: [],
          command: nil,
          prompt_to: nil
        }

        assign_page(socket, project, scope, page)
      else
        {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
      end
    end)
  end

  def handle_params(
        %{"component_id" => component_id, "name" => req_name},
        _uri,
        %{assigns: %{live_action: :component_req_prompt}} = socket
      ) do
    with_project(socket, fn project, scope ->
      component = Components.get_component!(scope, component_id)
      slug = socket.assigns.slug
      node = find_entity_node(scope, "component", component.id, req_name)

      if node && node.satisfied_by do
        task = %{component_id: component_id, component_module_name: component.module_name}

        page = %{
          kind: :command,
          title: "#{component.module_name} / #{req_name}",
          command: fetch_prompt_text(node.satisfied_by, scope, task),
          back: %{
            label: "← Back to #{req_name}",
            to: "/app/projects/#{slug}/components/#{component_id}/requirements/#{req_name}"
          }
        }

        assign_page(socket, project, scope, page)
      else
        {:noreply, assign(socket, error: "Requirement #{req_name} has no task module")}
      end
    end)
  end

  def handle_params(
        %{"component_id" => component_id, "name" => req_name},
        _uri,
        %{assigns: %{live_action: :component_req_show}} = socket
      ) do
    with_project(socket, fn project, scope ->
      component = Components.get_component!(scope, component_id)
      slug = socket.assigns.slug
      node = find_entity_node(scope, "component", component.id, req_name)

      assign_component_req(socket, project, scope, component, slug, req_name, node)
    end)
  end

  def handle_params(%{}, _uri, %{assigns: %{live_action: :components_graph}} = socket) do
    with_project(socket, fn project, scope ->
      assign_graph(socket, project, scope, GraphProjector.components_graph(scope))
    end)
  end

  def handle_params(%{}, _uri, %{assigns: %{live_action: :components}} = socket) do
    with_project(socket, fn project, scope ->
      components = Components.list_components(scope)
      {nodes, _computed_at} = Requirements.cached_all(scope)
      slug = socket.assigns.slug

      items =
        Enum.map(components, fn component ->
          {satisfied, total} = entity_counts(nodes, "component", component.id)

          %{
            label: component.module_name,
            to: "/app/projects/#{slug}/components/#{component.id}",
            satisfied: satisfied,
            total: total
          }
        end)

      page = %{
        kind: :list,
        title: "Components",
        items: items,
        back: %{label: "← Back to project", to: "/app/projects/#{slug}"}
      }

      assign_page(socket, project, scope, page)
    end)
  end

  def handle_params(
        %{"component_id" => component_id},
        _uri,
        %{assigns: %{live_action: :component_graph}} = socket
      ) do
    with_project(socket, fn project, scope ->
      assign_graph(socket, project, scope, GraphProjector.component_graph(scope, component_id))
    end)
  end

  def handle_params(
        %{"component_id" => component_id},
        _uri,
        %{assigns: %{live_action: :component_show}} = socket
      ) do
    with_project(socket, fn project, scope ->
      component = Components.get_component!(scope, component_id)
      {nodes, _computed_at} = Requirements.cached_all(scope)
      slug = socket.assigns.slug
      {satisfied, total} = entity_counts(nodes, "component", component.id)

      stories =
        scope
        |> Stories.list_component_stories(component.id)
        |> Enum.map(fn s -> %{label: s.title, to: "/app/projects/#{slug}/stories/#{s.id}"} end)

      req_items =
        entity_req_items(nodes, "component", component.id, fn n ->
          "/app/projects/#{slug}/components/#{component.id}/requirements/#{n.name}"
        end)

      page = %{
        kind: :entity,
        title: component.module_name,
        subtitle: "Type: #{component.type}",
        satisfied: satisfied,
        total: total,
        stories: stories,
        req_items: req_items,
        back: %{label: "← Back to requirements", to: "/app/projects/#{slug}/requirements"}
      }

      assign_page(socket, project, scope, page)
    end)
  end

  def handle_params(
        %{"story_id" => story_id},
        _uri,
        %{assigns: %{live_action: :story_show}} = socket
      ) do
    with_project(socket, fn project, scope ->
      story = Stories.get_story!(scope, story_id)
      {nodes, _computed_at} = Requirements.cached_all(scope)
      slug = socket.assigns.slug
      {satisfied, total} = entity_counts(nodes, "story", story.id)

      req_items =
        entity_req_items(nodes, "story", story.id, fn n ->
          "/app/projects/#{slug}/stories/#{story.id}/requirements/#{n.name}"
        end)

      page = %{
        kind: :entity,
        title: story.title,
        subtitle: nil,
        satisfied: satisfied,
        total: total,
        stories: nil,
        req_items: req_items,
        back: %{label: "← Back to stories", to: "/app/projects/#{slug}/stories"}
      }

      assign_page(socket, project, scope, page)
    end)
  end

  def handle_params(%{}, _uri, %{assigns: %{live_action: :stories}} = socket) do
    with_project(socket, fn project, scope ->
      {:ok, stories} = Stories.list_project_stories(scope)
      {nodes, _computed_at} = Requirements.cached_all(scope)
      slug = socket.assigns.slug

      items =
        Enum.map(stories, fn story ->
          {satisfied, total} = entity_counts(nodes, "story", story.id)

          %{
            label: story.title,
            to: "/app/projects/#{slug}/stories/#{story.id}",
            satisfied: satisfied,
            total: total
          }
        end)

      page = %{kind: :list, title: "Stories", items: items, back: nil}

      assign_page(socket, project, scope, page)
    end)
  end

  def handle_params(%{} = params, _uri, %{assigns: %{live_action: :graph}} = socket) do
    with_project(socket, fn project, scope ->
      socket = maybe_watch(socket, scope)

      base =
        assign(socket, project: project, scope: scope, page: nil, error: nil, setup_error: nil)

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

  def handle_params(%{}, _uri, socket) do
    with_project(socket, fn project, scope ->
      {nodes, _computed_at} = Requirements.cached_all(scope)
      actionable = Requirements.next_actionable_project(scope)
      actionable_names = MapSet.new(actionable, & &1.name)

      page = %{
        kind: :index,
        satisfied: Enum.count(nodes, &(&1.entity_type == "project" and &1.satisfied)),
        total: Enum.count(nodes, &(&1.entity_type == "project")),
        items: project_req_items(nodes, socket.assigns.slug, actionable_names)
      }

      assign_page(socket, project, scope, page)
    end)
  end

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

  # File watcher fired for this project. Debounce on the trailing edge so a
  # burst of saves coalesces into a single recompute once edits settle.
  @impl true
  def handle_info({:watcher_synced, _info}, %{assigns: %{live_action: :graph}} = socket) do
    if ref = socket.assigns.graph_timer, do: Process.cancel_timer(ref)
    timer = Process.send_after(self(), :graph_recompute, @graph_debounce_ms)
    {:noreply, assign(socket, graph_timer: timer)}
  end

  def handle_info({:watcher_synced, _info}, socket), do: {:noreply, socket}

  def handle_info(:graph_recompute, %{assigns: %{scope: scope}} = socket)
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
    |> push_event("graph:ready", %{data: graph_data, metrics: metrics})
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
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
      slug={@slug}
      socket={@socket}
    />

    <div
      :if={@live_action in [:index, :stories] && @project}
      role="tablist"
      class="tabs tabs-bordered mb-4"
    >
      <.link
        patch={path(@socket, ~p"/app/projects/#{@slug}/requirements")}
        role="tab"
        class={["tab", @live_action == :index && "tab-active"]}
      >
        Project
      </.link>
      <.link
        patch={path(@socket, ~p"/app/projects/#{@slug}/requirements/stories")}
        role="tab"
        class={["tab", @live_action == :stories && "tab-active"]}
      >
        Stories
      </.link>
    </div>

    <.index_view :if={@page && @page.kind == :index} page={@page} project={@project} />
    <.list_view :if={@page && @page.kind == :list} page={@page} />
    <.entity_view :if={@page && @page.kind == :entity} page={@page} />
    <.requirement_view :if={@page && @page.kind == :requirement} page={@page} />
    <.command_view :if={@page && @page.kind == :command} page={@page} />
    """
  end

  # --- Page components ---

  attr :project, :map, required: true
  attr :graph_data, :any, required: true

  # Host-provided assigns have to be declared: a component invoked as
  # `<.graph_view ...>` receives only what it names, so @slug and @socket
  # would raise KeyError the first time a graph renders.
  attr :slug, :string, required: true
  attr :socket, :map, required: true

  defp graph_view(assigns) do
    ~H"""
    <div id="graph-page">
      <div class="mb-4">
        <.link navigate={"/app/projects/#{@slug}/requirements"} class="btn btn-ghost btn-sm gap-1">
          ← Back to requirements
        </.link>
      </div>
      <h1 class="text-2xl font-bold mb-4">Requirements Graph</h1>
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
        data-graph={if is_map(@graph_data), do: Jason.encode!(@graph_data)}
        phx-update="ignore"
        class="rounded-box border border-base-300 bg-base-200"
        style="width: 100%; height: 80vh;"
      >
      </div>
    </div>
    """
  end

  attr :page, :map, required: true
  attr :project, :map, required: true

  defp index_view(assigns) do
    ~H"""
    <div>
      <header class="mb-4">
        <h1 class="text-2xl font-bold">{@project.name || "Project"} — Requirements</h1>
        <p class="text-base-content/60 mt-1">{@page.satisfied} of {@page.total} satisfied</p>
      </header>

      <ul class="space-y-1.5">
        <li
          :for={item <- @page.items}
          data-test="requirement"
          data-requirement={item.name}
          data-satisfied={to_string(item.satisfied)}
          data-basis={item[:basis]}
          class="flex items-start gap-3 rounded-box border border-base-300 bg-base-200 p-3"
        >
          <.status_icon satisfied={item.satisfied} />
          <div class="min-w-0 flex-1">
            <.link
              navigate={item.to}
              class="link link-hover font-semibold font-mono text-sm break-all"
            >
              {item.name}
            </.link>
            <span :if={item.actionable} class="badge badge-success badge-sm ml-2 align-middle">
              actionable
            </span>
            <p class="text-sm text-base-content/70 mt-1">{item.description}</p>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :page, :map, required: true

  defp list_view(assigns) do
    ~H"""
    <div>
      <.back_link :if={@page.back} back={@page.back} />
      <h1 class="text-2xl font-bold mb-4">{@page.title}</h1>

      <ul class="space-y-1.5">
        <li
          :for={item <- @page.items}
          class="flex items-center gap-3 rounded-box border border-base-300 bg-base-200 p-3"
        >
          <.status_icon satisfied={item.satisfied == item.total and item.total > 0} />
          <.link navigate={item.to} class="link link-hover flex-1 truncate">{item.label}</.link>
          <span class="badge badge-ghost badge-sm">{item.satisfied}/{item.total}</span>
        </li>
      </ul>

      <p :if={@page.items == []} class="text-base-content/50">Nothing here yet.</p>
    </div>
    """
  end

  attr :page, :map, required: true

  defp entity_view(assigns) do
    ~H"""
    <div>
      <.back_link back={@page.back} />
      <header class="mb-4">
        <h1 class="text-2xl font-bold font-mono break-all">{@page.title}</h1>
        <p class="text-base-content/60 mt-1">
          <span :if={@page.subtitle}>{@page.subtitle} · </span>{@page.satisfied} of {@page.total} satisfied
        </p>
      </header>

      <section :if={@page.stories && @page.stories != []} class="mb-5">
        <h2 class="text-base font-semibold mb-1.5">Stories</h2>
        <ul class="space-y-1">
          <li :for={story <- @page.stories}>
            <.link navigate={story.to} class="link link-hover">{story.label}</.link>
          </li>
        </ul>
      </section>

      <h2 class="text-base font-semibold mb-1.5">Requirements</h2>
      <ul class="space-y-1.5">
        <li
          :for={item <- @page.req_items}
          data-test="requirement"
          data-requirement={item.name}
          data-satisfied={to_string(item.satisfied)}
          class="flex items-start gap-3 rounded-box border border-base-300 bg-base-200 p-3"
        >
          <.status_icon satisfied={item.satisfied} />
          <div class="min-w-0 flex-1">
            <.link
              navigate={item.to}
              class="link link-hover font-semibold font-mono text-sm break-all"
            >
              {item.name}
            </.link>
            <span :if={item.actionable} class="badge badge-success badge-sm ml-2 align-middle">
              actionable
            </span>
            <p class="text-sm text-base-content/70 mt-1">{item.description}</p>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :page, :map, required: true

  defp requirement_view(assigns) do
    assigns = assign(assigns, :node, assigns.page.node)

    ~H"""
    <div>
      <.back_link back={@page.back} />
      <header class="mb-4">
        <h1 class="text-2xl font-bold font-mono break-all">{@node.name}</h1>
        <p class="text-base-content/70 mt-1">{@node.description}</p>
        <div class="mt-2 flex items-center gap-2">
          <.status_icon satisfied={@node.satisfied} />
          <span class={["badge", (@node.satisfied && "badge-success") || "badge-ghost"]}>
            {if @node.satisfied, do: "satisfied", else: "not satisfied"}
          </span>
        </div>
      </header>

      <p :if={@node.satisfied_by} class="text-sm text-base-content/60 mb-3">
        Satisfied by <code class="font-mono">{task_short_name(@node.satisfied_by)}</code>
      </p>

      <.link :if={@page.prompt_to} navigate={@page.prompt_to} class="btn btn-primary btn-sm mb-3">
        View Prompt →
      </.link>

      <div :if={@page.command} class="mb-4">
        <h2 class="text-base font-semibold mb-1.5">Command</h2>
        <div class="prose prose-sm max-w-none bg-base-200 border border-base-300 rounded-box p-4 overflow-x-auto">
          {md_html(@page.command)}
        </div>
      </div>

      <div :if={@node.details != %{}} class="mb-4">
        <h2 class="text-base font-semibold mb-1.5">Details</h2>
        <pre class="font-mono text-xs bg-base-200 border border-base-300 rounded-box p-4 overflow-x-auto">{Jason.encode!(@node.details, pretty: true)}</pre>
      </div>

      <section :if={@page.prereqs != []} class="mb-4">
        <h2 class="text-base font-semibold mb-1.5">Depends on</h2>
        <.req_pill_list links={@page.prereqs} />
      </section>

      <section :if={@page.dependents != []}>
        <h2 class="text-base font-semibold mb-1.5">Unblocks</h2>
        <.req_pill_list links={@page.dependents} />
      </section>
    </div>
    """
  end

  attr :page, :map, required: true

  defp command_view(assigns) do
    ~H"""
    <div>
      <.back_link back={@page.back} />
      <h1 class="text-2xl font-bold mb-4 break-all">{@page.title}</h1>
      <div class="prose prose-sm md:prose-base max-w-none bg-base-200 border border-base-300 rounded-box p-6 overflow-x-auto">
        {md_html(@page.command)}
      </div>
    </div>
    """
  end

  # --- Shared bits ---

  attr :satisfied, :boolean, required: true

  defp status_icon(assigns) do
    ~H"""
    <span
      class={[
        "mt-0.5 flex-none text-base leading-none",
        (@satisfied && "text-success") || "text-base-content/30"
      ]}
      aria-label={if @satisfied, do: "satisfied", else: "not satisfied"}
    >
      {if @satisfied, do: "✓", else: "○"}
    </span>
    """
  end

  attr :back, :map, required: true

  defp back_link(assigns) do
    ~H"""
    <div class="mb-3">
      <.link navigate={@back.to} class="btn btn-ghost btn-sm gap-1">{@back.label}</.link>
    </div>
    """
  end

  attr :links, :list, required: true

  defp req_pill_list(assigns) do
    ~H"""
    <ul class="flex flex-wrap gap-2">
      <li :for={link <- @links}>
        <.link
          navigate={link.to}
          class="inline-flex items-center gap-1 rounded-full border border-base-300 bg-base-200 px-3 py-1 text-sm hover:bg-base-300"
        >
          <.status_icon satisfied={link.satisfied} />
          <span class="font-mono">{link.name}</span>
        </.link>
      </li>
    </ul>
    """
  end

  # The checker's own sentence, whichever key it used. `details` is `%{status:
  # …}` when satisfied and `%{reason: …}` when not, and it comes back
  # string-keyed from the database and atom-keyed in memory — see
  # `Requirement.normalize_details/1` for why both shapes exist.
  defp basis(node) do
    details = node.details || %{}

    MapAccess.get(details, :status) || MapAccess.get(details, :reason)
  end

  defp entity_req_items(nodes, entity_type, entity_id, to_fun) do
    entity_nodes = entity_nodes(nodes, entity_type, entity_id)
    actionable = MapSet.new(actionable_nodes(entity_nodes), & &1.name)

    Enum.map(entity_nodes, fn n ->
      %{
        name: n.name,
        description: n.description,
        satisfied: n.satisfied,
        # Why, from the checker. A satisfied node can mean opposite things —
        # `work_dispatched` is satisfied both when a project is finished and
        # when it is merely busy — and without the basis the page cannot tell
        # them apart any better than a bare tick can.
        basis: basis(n),
        actionable: MapSet.member?(actionable, n.name),
        to: to_fun.(n)
      }
    end)
  end

  defp prereq_data(node, all_nodes, slug) do
    project_nodes = Enum.filter(all_nodes, &(&1.entity_type == "project"))

    Enum.map(node.prerequisites, fn prereq_name ->
      prereq = Enum.find(project_nodes, &(&1.name == prereq_name))

      %{
        name: prereq_name,
        satisfied: (prereq && prereq.satisfied) == true,
        to: "/app/projects/#{slug}/requirements/#{prereq_name}"
      }
    end)
  end

  defp dependent_data(node, all_nodes, slug) do
    all_nodes
    |> Enum.filter(&(&1.entity_type == "project" and node.name in &1.prerequisites))
    |> Enum.map(fn n ->
      %{name: n.name, satisfied: n.satisfied, to: "/app/projects/#{slug}/requirements/#{n.name}"}
    end)
  end

  # --- Helpers ---

  defp handle_show_for_project(project, scope, req_name, socket) do
    {nodes, _computed_at} = Requirements.cached_all(scope)
    node = Enum.find(nodes, &(&1.entity_type == "project" and &1.name == req_name))

    if node do
      slug = socket.assigns.slug

      {command, setup_error} =
        case show_command(node, scope) do
          {:ok, text} -> {text, nil}
          {:error, reason} -> {nil, inspect(reason)}
        end

      page = %{
        kind: :requirement,
        node: node,
        back: %{label: "← Back to requirements", to: "/app/projects/#{slug}/requirements"},
        prereqs: prereq_data(node, nodes, slug),
        dependents: dependent_data(node, nodes, slug),
        command: command,
        prompt_to: nil
      }

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         page: page,
         graph_data: nil,
         error: nil,
         setup_error: setup_error
       )}
    else
      {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
    end
  end

  defp show_command(%{render_command_always?: true, satisfied_by: satisfied_by}, scope)
       when not is_nil(satisfied_by) do
    satisfied_by.command(scope, %{})
  end

  defp show_command(%{satisfied_by: satisfied_by, satisfied: false}, scope)
       when not is_nil(satisfied_by),
       do: {:ok, generate_command(satisfied_by, scope)}

  defp show_command(_node, _scope), do: {:ok, nil}

  defp find_entity_node(scope, entity_type, entity_id, req_name) do
    scope
    |> Requirements.compute_all()
    |> Enum.find(fn n ->
      n.entity_type == entity_type and n.entity_id == entity_id and n.name == req_name
    end)
  end

  defp entity_nodes(nodes, entity_type, entity_id),
    do: Enum.filter(nodes, &(&1.entity_type == entity_type and &1.entity_id == entity_id))

  defp actionable_nodes(entity_nodes),
    do: Enum.filter(entity_nodes, fn n -> !n.satisfied and n.satisfied_by end)

  defp entity_counts(nodes, entity_type, entity_id) do
    entity_nodes = entity_nodes(nodes, entity_type, entity_id)
    {Enum.count(entity_nodes, & &1.satisfied), length(entity_nodes)}
  end

  defp task_short_name(module),
    do: module |> inspect() |> String.split(".") |> List.last()

  defp fetch_prompt_text(satisfied_by, scope, task) do
    case satisfied_by.command(scope, task) do
      {:ok, text} -> text
      {:error, reason} -> "Error generating prompt: #{AgentTasks.format_error(reason)}"
    end
  end

  defp generate_command(task_module, scope) do
    case task_module.command(scope, %{}) do
      {:ok, text} -> text
      {:error, reason} -> "Error: #{AgentTasks.format_error(reason)}"
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  # The host resolves the project from the route before any handle_params runs,
  # so this is now a guard rather than a lookup — every clause still funnels
  # through it, which is what kept this view's migration to a handful of lines.
  defp project_req_items(nodes, slug, actionable_names) do
    definition_order =
      RequirementDefinitionData.project_requirements()
      |> Enum.with_index()
      |> Map.new(fn {defn, idx} -> {defn.name, idx} end)

    nodes
    |> Enum.filter(&(&1.entity_type == "project"))
    |> Enum.sort_by(fn n -> Map.get(definition_order, n.name, 999) end)
    |> Enum.map(fn n ->
      %{
        name: n.name,
        description: n.description,
        satisfied: n.satisfied,
        basis: basis(n),
        actionable: MapSet.member?(actionable_names, n.name),
        to: "/app/projects/#{slug}/requirements/#{n.name}"
      }
    end)
  end

  defp with_project(%{assigns: %{scope: %{} = scope, project: project}} = _socket, fun),
    do: fun.(project, scope)

  defp with_project(socket, _fun),
    do: {:noreply, assign(socket, error: socket.assigns.scope_error, page: nil, graph_data: nil)}

  defp assign_page(socket, project, scope, page) do
    {:noreply,
     assign(socket,
       project: project,
       scope: scope,
       page: page,
       graph_data: nil,
       error: nil,
       setup_error: nil
     )}
  end

  defp assign_component_req(socket, _project, _scope, _component, _slug, req_name, nil) do
    {:noreply, assign(socket, error: "Requirement not found: #{req_name}")}
  end

  defp assign_component_req(socket, project, scope, component, slug, req_name, node) do
    prompt_to =
      if node.satisfied_by,
        do: "/app/projects/#{slug}/components/#{component.id}/requirements/#{req_name}/prompt",
        else: nil

    page = %{
      kind: :requirement,
      node: node,
      back: %{
        label: "← Back to #{component.module_name}",
        to: "/app/projects/#{slug}/components/#{component.id}"
      },
      prereqs: [],
      dependents: [],
      command: nil,
      prompt_to: prompt_to
    }

    assign_page(socket, project, scope, page)
  end

  defp assign_graph(socket, project, scope, graph_data) do
    {:noreply,
     assign(socket,
       project: project,
       scope: scope,
       page: nil,
       graph_data: graph_data,
       error: nil,
       setup_error: nil
     )}
  end
end
