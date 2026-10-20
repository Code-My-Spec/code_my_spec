defmodule CodeMySpecWeb.ProjectTimeline do
  @moduledoc """
  Where a project stands, across the top of the main agent's conversation, in
  the five bands its graph runs through (`Requirements.Bands`):

      ● ● ● ●  [stories ▓▓▒░░]  [components ████░ 62%]  [stories ▓▒░░░]  ● ○

  Each band at the grain its work has. The project gates either end are
  serial, so each is a mark of its own. Story work is parallel, so it is a
  count — done, partial, open issues, not started — not a mark per story. The
  components are a DAG with no useful order to draw on one line, so they are a
  continuous bar.

  A LiveComponent because the bands are read from the database: once on mount
  and again when the parent forwards a graph update
  (`send_update(ProjectTimeline, id: "project-timeline", refresh: true)`), never
  on every render.

  The graph opens in a modal (`RequirementGraphComponents.modal/1`) from the
  button at the end, or from a gate with that gate selected; it is computed off
  the LiveView process, only when asked for.
  """

  use CodeMySpecWeb, :live_component

  alias CodeMySpec.AgentPerformance.Chart
  alias CodeMySpec.Architecture.BoundaryGraph
  alias CodeMySpec.Qa
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Bands
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.PlainLanguage
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpecWeb.ActivityComponents
  alias CodeMySpecWeb.QaComponents
  alias CodeMySpecWeb.RequirementGraphComponents

  @doc """
  The timeline for a project, or nothing at all when there is none in scope.
  """
  attr(:scope, :map, required: true)
  attr(:project, :any, default: nil)
  attr(:variant, :atom, default: :strip, values: [:strip, :header])

  def project_timeline(assigns) do
    ~H"""
    <.live_component
      :if={@project && @project.id}
      module={__MODULE__}
      id="project-timeline"
      scope={@scope}
      project={@project}
      variant={@variant}
    />
    """
  end

  @impl true
  def update(assigns, socket) do
    {refresh?, assigns} = Map.pop(assigns, :refresh, false)
    socket = assign(socket, assigns)

    socket =
      socket
      |> assign_new(:graph_modal, fn -> nil end)
      |> assign_new(:selected, fn -> nil end)
      |> assign_new(:detail, fn -> %{} end)

    if refresh? or not Map.has_key?(socket.assigns, :bands),
      do:
        {:ok,
         assign(socket,
           bands: Bands.read(socket.assigns.scope),
           architecture: BoundaryGraph.build(socket.assigns.scope).summary,
           qa:
             socket.assigns.scope
             |> Qa.list_project_attempts(include_older: true)
             |> QaComponents.recent_counts(),
           activity: Chart.week_summary(socket.assigns.scope)
         )},
      else: {:ok, socket}
  end

  # Off the LiveView process, and only when asked for: the projected graph and
  # every requirement, keyed as the graph keys its nodes.
  @impl true
  def handle_event("open_graph", params, socket) do
    scope = socket.assigns.scope
    project = socket.assigns.project

    {:noreply,
     socket
     |> assign(graph_modal: :loading, selected: focus_key(project, params["focus"]))
     |> start_async(:graph, fn -> load_graph(scope) end)}
  end

  def handle_event("select_node", %{"key" => key}, socket),
    do: {:noreply, socket |> assign(:selected, key) |> with_detail()}

  def handle_event("close_graph", _params, socket),
    do: {:noreply, assign(socket, graph_modal: nil, selected: nil)}

  @impl true
  def handle_async(:graph, {:ok, graph}, %{assigns: %{graph_modal: :loading}} = socket),
    do: {:noreply, socket |> assign(:graph_modal, graph) |> with_detail()}

  def handle_async(:graph, {:exit, _reason}, %{assigns: %{graph_modal: :loading}} = socket),
    do: {:noreply, assign(socket, :graph_modal, :error)}

  def handle_async(:graph, _result, socket), do: {:noreply, socket}

  defp with_detail(%{assigns: %{graph_modal: %{requirements: reqs}, selected: key}} = socket)
       when is_binary(key) do
    case reqs[key] do
      nil ->
        assign(socket, :detail, %{})

      node ->
        assign(socket, :detail, RequirementGraphComponents.detail(socket.assigns.scope, node))
    end
  end

  defp with_detail(socket), do: assign(socket, :detail, %{})

  defp load_graph(scope) do
    {data, _metrics} = GraphProjector.project_graph_with_metrics(scope)
    {nodes, _computed_at} = Requirements.cached_all(scope)
    %{data: data, requirements: Map.new(nodes, &{GraphProjector.key(&1), &1})}
  end

  defp focus_key(_project, nil), do: nil
  defp focus_key(project, name), do: "project_#{String.replace(project.id, "-", "")}_#{name}"

  @impl true
  def render(assigns) do
    {early, late} = gates(assigns.bands)
    graph = ~p"/app/projects/#{assigns.project.id}/requirements/graph"
    assigns = assign(assigns, early: early, late: late, graph: graph)

    ~H"""
    <nav
      id={@id}
      data-test="project-timeline"
      aria-label="Where this project stands"
      class={[
        "w-full",
        @variant == :strip && "border-b border-base-300 bg-base-200/50 px-4 py-2 lg:px-8"
      ]}
    >
      <%!-- From sm up, a grid, so the stories chart always keeps a track of its
      own: gates, the chart taking what is left, gates, then the counts. On a
      phone it flows instead: both gate groups on one line, the chart across
      the full width, then the counts wrapping as they need. --%>
      <div class="flex w-full flex-wrap items-center gap-x-3 gap-y-2 sm:grid sm:grid-cols-[auto_minmax(6rem,1fr)_auto_auto]">
        <div
          data-test="timeline-band"
          data-band="early"
          class="order-1 flex shrink-0 flex-nowrap items-center gap-1 sm:order-none"
        >
          <.gate :for={step <- @early} step={step} tip="tooltip-right" target={@myself} />
        </div>
        <div
          data-test="timeline-band"
          data-band="stories"
          class="timeline-more order-3 min-w-0 basis-full max-sm:hidden sm:order-none sm:basis-auto"
        >
          <.story_chart stories={@bands.stories} />
        </div>
        <div
          data-test="timeline-band"
          data-band="late"
          class="order-2 flex shrink-0 flex-nowrap items-center gap-1 sm:order-none"
        >
          <.gate :for={step <- @late} step={step} tip="tooltip-left" target={@myself} />
        </div>
        <%!-- On a phone only the gates show; this opens the rest. JS, so the
        open state survives the page's own updates. --%>
        <button
          type="button"
          data-test="timeline-expand"
          aria-label="Show stories and counts"
          phx-click={
            JS.toggle_class("max-sm:hidden", to: "##{@id} .timeline-more")
            |> JS.toggle_class("rotate-180", to: "##{@id} .timeline-expand-icon")
          }
          class="order-2 btn btn-ghost btn-xs btn-square sm:hidden"
        >
          <.icon name="hero-chevron-down" class="timeline-expand-icon size-4 transition-transform" />
        </button>
        <%!-- Where it stands, counted. --%>
        <ul class="timeline-more order-4 flex basis-full flex-wrap items-center gap-x-3 gap-y-1 max-sm:hidden sm:order-none sm:basis-auto sm:flex-nowrap">
          <li data-test="timeline-band" data-band="story-counts">
            <.labelled label="Stories">
              <.story_counts counts={@bands.story_counts} first={List.first(@bands.stories)} />
            </.labelled>
          </li>
          <li data-test="timeline-band" data-band="components">
            <.labelled label="Impl">
              <.component_bar counts={@bands.components} target={@myself} />
            </.labelled>
          </li>
          <li data-test="timeline-band" data-band="architecture">
            <.labelled label="Arch">
              <.architecture_mark summary={@architecture} project={@project} />
            </.labelled>
          </li>
          <li data-test="timeline-band" data-band="activity">
            <.labelled label="Week">
              <ActivityComponents.summary_mark summary={@activity} phx-click="show_activity" />
            </.labelled>
          </li>
          <li data-test="timeline-band" data-band="qa">
            <.labelled label="QA">
              <QaComponents.counts_mark counts={@qa} phx-click="show_qa" />
            </.labelled>
          </li>
          <li data-test="timeline-band" data-band="issues">
            <.labelled label="Issues">
              <.issue_bar counts={@bands.issues} target={@myself} />
            </.labelled>
          </li>
          <li>
            <button
              type="button"
              phx-click="open_graph"
              phx-target={@myself}
              data-test="open-graph"
              title="Open the requirements graph"
              aria-label="Open the requirements graph"
              class="btn btn-ghost btn-xs btn-square"
            >
              <.icon name="hero-share" class="size-4" />
            </button>
          </li>
        </ul>
      </div>
      <RequirementGraphComponents.modal
        :if={@graph_modal}
        graph={@graph_modal}
        selected={@selected}
        detail={@detail}
        href={@graph}
        target={@myself}
        target_selector={"##{@id}"}
      />
    </nav>
    """
  end

  attr(:step, :map, required: true)
  attr(:tip, :string, required: true, doc: "which way the tooltip opens, away from the edge")
  attr(:target, :any, required: true)

  # A project gate: a dot, or the pill naming it when it is the one the project
  # is on. Exactly one gate is current, always — an idle project is the
  # ordinary overnight state, and a strip marking nothing then reads as broken.
  defp gate(assigns) do
    ~H"""
    <span data-test="timeline-step" data-step={@step.name} data-state={@step.state}>
      <.link
        phx-click="open_graph"
        phx-value-focus={@step.name}
        phx-target={@target}
        data-tip={@step.title}
        class={["tooltip flex h-4 items-center", @tip]}
      >
        <span
          :if={@step.state == "current"}
          data-test="current-step"
          class="flex h-4 items-center rounded-full bg-primary px-1.5 text-[0.6rem] font-semibold uppercase leading-none tracking-wide text-primary-content"
        >
          {@step.abbrev}
        </span>
        <span
          :if={@step.state != "current"}
          class={[
            "block size-2 rounded-full",
            @step.state == "done" && "bg-success",
            @step.state == "todo" && "bg-base-content/20"
          ]}
        ></span>
        <span class="sr-only">{@step.title}</span>
      </.link>
    </span>
    """
  end

  attr(:stories, :list, required: true)

  # Every story in progress, one thin column each, furthest along first. A column is the
  # story's steps stacked from the bottom: done (green), the one it is on
  # (yellow), held by open issues (red), not reached yet (grey). Side by side they fall away left to
  # right like a stacked line, and the shape says how far along the stories
  # are as a body of work.
  # A column opens that story's requirements graph in the cockpit
  # (`show_story_graph`), with a slider through the stories in this order and a
  # switch to the story's text.
  defp story_chart(assigns) do
    ~H"""
    <div
      data-test="story-chart"
      data-stories={length(@stories)}
      aria-label={"#{length(@stories)} stories, by how far each has got"}
      class="tooltip tooltip-bottom block w-full"
    >
      <span data-test="story-legend" class="tooltip-content text-left text-xs">
        <span :for={{label, class} <- legend()} class="flex items-center gap-1.5">
          <span class={["size-2 rounded-sm", class]}></span>{label}
        </span>
      </span>
      <span class="group flex h-7 w-full items-stretch overflow-hidden rounded-sm bg-base-content/10">
        <span
          :for={story <- @stories}
          data-test="story-column"
          data-story-id={story.id}
          title={story_title(story)}
          phx-click="show_story_graph"
          phx-value-story-id={story.id}
          phx-value-copy-id={story.working_copy_id}
          phx-value-from="chart"
          class="flex min-w-0 flex-1 cursor-pointer flex-col-reverse transition-opacity group-hover:opacity-50 hover:opacity-100!"
        >
          <span
            :for={{key, class} <- step_segments()}
            :if={story[key] > 0}
            class={["w-full shrink-0", class]}
            style={"height: #{story[key] / max(step_total(story), 1) * 100}%"}
          ></span>
        </span>
      </span>
    </div>
    """
  end

  defp legend,
    do: [
      {"Steps done", "bg-success"},
      {"Working on", "bg-warning"},
      {"Held by open issues", "bg-error"},
      {"Not reached yet", "bg-base-content/25"}
    ]

  # Not-started steps on top in grey, so every column is the story's full height.
  defp step_segments,
    do: [
      done: "bg-success",
      working: "bg-warning",
      issues: "bg-error",
      none: "bg-base-content/25"
    ]

  defp step_total(story), do: story.done + story.working + story.issues + story.none

  defp story_title(story),
    do: "##{story.number} #{story.title} — #{story.done} of #{step_total(story)} steps"

  attr(:counts, :map, required: true)
  attr(:first, :map, default: nil, doc: "the chart's first story, which a tap opens")

  # The stories the chart leaves out: done (promoted), backlog (not yet ready
  # for development), retired.
  defp story_counts(assigns) do
    assigns =
      assign(assigns,
        tip:
          "Stories: #{assigns.counts.done} done · #{assigns.counts.backlog} in the backlog · " <>
            "#{assigns.counts.retired} retired"
      )

    ~H"""
    <button
      type="button"
      phx-click={@first && "show_chart_story"}
      phx-value-number={@first && @first.number}
      data-test="story-counts"
      data-done={@counts.done}
      data-backlog={@counts.backlog}
      data-retired={@counts.retired}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex shrink-0 items-center gap-0.5 font-mono text-xs tabular-nums"
    >
      <span class="text-success">{@counts.done}</span>
      <span class="opacity-30">/</span>
      <span class="opacity-50">{@counts.backlog}</span>
      <span class="opacity-30">/</span>
      <span class="opacity-30">{@counts.retired}</span>
    </button>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  # A small heading over a group of counts, so neighbouring numbers do not read
  # as one row.
  defp labelled(assigns) do
    ~H"""
    <span class="flex shrink-0 flex-col items-center gap-0.5 leading-none">
      <span class="text-xs font-normal uppercase leading-none tracking-[0.2em] opacity-40">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr(:summary, :map, required: true)
  attr(:project, :map, required: true)

  # The architecture's health from `BoundaryGraph`: how many boundary cycles
  # (red when any) and how deep the longest chain of boundaries runs.
  defp architecture_mark(assigns) do
    cycles = length(assigns.summary.cycles)
    chain = Enum.join(assigns.summary.longest_chain, " → ")

    assigns =
      assign(assigns,
        cycles: cycles,
        tip:
          "Architecture: #{cycles} #{if cycles == 1, do: "cycle", else: "cycles"} · " <>
            "#{assigns.summary.depth} deep" <> if(chain != "", do: " (#{chain})", else: "")
      )

    ~H"""
    <.link
      navigate={~p"/app/projects/#{@project.id}/architecture"}
      data-test="architecture-mark"
      data-cycles={@cycles}
      data-depth={@summary.depth}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-left flex items-center gap-2 font-mono text-xs tabular-nums"
    >
      <span class={[
        "flex items-center gap-0.5",
        if(@cycles > 0, do: "text-error", else: "opacity-50")
      ]}>
        <.icon name="hero-arrow-path" class="size-3" />{@cycles}
      </span>
      <span data-test="architecture-depth" class="flex items-center gap-0.5 opacity-60">
        <.icon name="hero-list-bullet" class="size-3" />{@summary.depth}
      </span>
    </.link>
    """
  end

  attr(:counts, :map, required: true)
  attr(:target, :any, required: true)

  # Issues as three counts, closed to open: resolved (green), dismissed
  # (grey), open (red).
  defp issue_bar(assigns) do
    %{resolved: resolved, dismissed: dismissed, open: open} = assigns.counts

    assigns =
      assign(assigns,
        resolved: resolved,
        dismissed: dismissed,
        open: open,
        tip: "Issues: #{resolved} resolved · #{dismissed} dismissed · #{open} open"
      )

    ~H"""
    <button
      type="button"
      phx-click="show_issues"
      data-test="issue-bar"
      data-resolved={@resolved}
      data-dismissed={@dismissed}
      data-open={@open}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-left flex items-center justify-center gap-0.5 font-mono text-xs tabular-nums"
    >
      <span class="text-success">{@resolved}</span>
      <span class="opacity-30">/</span>
      <span class="opacity-50">{@dismissed}</span>
      <span class="opacity-30">/</span>
      <span class={if @open > 0, do: "text-error", else: "opacity-50"}>{@open}</span>
    </button>
    """
  end

  attr(:counts, :map, required: true)
  attr(:target, :any, required: true)

  # Components as three counts: planned and done (green), planned and not done
  # (grey), and found on disk without being planned (amber).
  defp component_bar(assigns) do
    %{done: done, not_done: not_done, unspecified: unspecified} = assigns.counts

    assigns =
      assign(assigns,
        done: done,
        not_done: not_done,
        unspecified: unspecified,
        tip:
          "Components: #{done} done · #{not_done} not done · #{unspecified} built without being specified"
      )

    ~H"""
    <button
      type="button"
      phx-click="open_graph"
      phx-target={@target}
      data-test="component-bar"
      data-done={@done}
      data-not-done={@not_done}
      data-unspecified={@unspecified}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex items-center justify-center gap-0.5 font-mono text-xs tabular-nums"
    >
      <span class="text-success">{@done}</span>
      <span class="opacity-30">/</span>
      <span class="opacity-50">{@not_done}</span>
      <span class="opacity-30">/</span>
      <span class="text-warning">{@unspecified}</span>
    </button>
    """
  end

  # The gates in template order, split where stories join, each with its state.
  defp gates(bands) do
    names = Enum.map(RequirementDefinitionData.project_graph(), & &1.name)
    current = Enum.find(names, List.last(names), &(not MapSet.member?(bands.satisfied, &1)))

    names
    |> Enum.map(&step(&1, bands.satisfied, current))
    |> Enum.split_with(&(not MapSet.member?(bands.late_names, &1.name)))
  end

  defp step(name, satisfied, current) do
    meaning = PlainLanguage.fetch(name) || %{}

    %{
      name: name,
      title: Map.get(meaning, :title, String.replace(name, "_", " ")),
      abbrev: Map.get(meaning, :abbrev, name |> String.split("_") |> hd()),
      state: state_of(name, satisfied, current)
    }
  end

  defp state_of(name, _satisfied, name), do: "current"

  defp state_of(name, satisfied, _current),
    do: if(MapSet.member?(satisfied, name), do: "done", else: "todo")
end
