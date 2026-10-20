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

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Bands
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.PlainLanguage
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpecWeb.RequirementGraphComponents

  @doc """
  The timeline for a project, or nothing at all when there is none in scope.
  """
  attr :scope, :map, required: true
  attr :project, :any, default: nil

  def project_timeline(assigns) do
    ~H"""
    <.live_component
      :if={@project && @project.id}
      module={__MODULE__}
      id="project-timeline"
      scope={@scope}
      project={@project}
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

    if refresh? or not Map.has_key?(socket.assigns, :bands),
      do: {:ok, assign(socket, :bands, Bands.read(socket.assigns.scope))},
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
    do: {:noreply, assign(socket, :selected, key)}

  def handle_event("close_graph", _params, socket),
    do: {:noreply, assign(socket, graph_modal: nil, selected: nil)}

  @impl true
  def handle_async(:graph, {:ok, graph}, %{assigns: %{graph_modal: :loading}} = socket),
    do: {:noreply, assign(socket, :graph_modal, graph)}

  def handle_async(:graph, {:exit, _reason}, %{assigns: %{graph_modal: :loading}} = socket),
    do: {:noreply, assign(socket, :graph_modal, :error)}

  def handle_async(:graph, _result, socket), do: {:noreply, socket}

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
      class="w-full border-b border-base-300 bg-base-200/50 px-4 py-2 lg:px-8"
    >
      <ol class="flex w-full items-center gap-3">
        <li data-test="timeline-band" data-band="early" class="flex shrink-0 items-center gap-1">
          <.gate :for={step <- @early} step={step} tip="tooltip-right" target={@myself} />
        </li>
        <li data-test="timeline-band" data-band="stories" class="min-w-16 flex-1">
          <.story_chart stories={@bands.stories} target={@myself} />
        </li>
        <li data-test="timeline-band" data-band="components" class="min-w-16 flex-1">
          <.component_bar counts={@bands.components} target={@myself} />
        </li>
        <li data-test="timeline-band" data-band="issues" class="min-w-16 flex-1">
          <.issue_bar counts={@bands.issues} target={@myself} />
        </li>
        <li data-test="timeline-band" data-band="late" class="flex shrink-0 items-center gap-1">
          <.gate :for={step <- @late} step={step} tip="tooltip-left" target={@myself} />
        </li>
        <li class="shrink-0">
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
      </ol>
      <RequirementGraphComponents.modal
        :if={@graph_modal}
        graph={@graph_modal}
        selected={@selected}
        href={@graph}
        target={@myself}
        target_selector={"##{@id}"}
      />
    </nav>
    """
  end

  attr :step, :map, required: true
  attr :tip, :string, required: true, doc: "which way the tooltip opens, away from the edge"
  attr :target, :any, required: true

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

  attr :stories, :list, required: true
  attr :target, :any, required: true

  # Every story, one thin column each, most complete first. A column is the
  # story's steps stacked from the bottom: done (green), the one it is on
  # (yellow), held by open issues (red), not reached yet (grey). Side by side they fall away left to
  # right like a stacked line, and the shape says how far along the stories
  # are as a body of work.
  defp story_chart(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_graph"
      phx-target={@target}
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
      <span class="flex h-5 w-full items-stretch overflow-hidden rounded-sm bg-base-content/10">
        <span
          :for={story <- @stories}
          data-test="story-column"
          title={story_title(story)}
          class="flex min-w-0 flex-1 flex-col-reverse"
        >
          <span
            :for={{key, class} <- step_segments()}
            :if={story[key] > 0}
            class={["w-full shrink-0", class]}
            style={"height: #{story[key] / max(step_total(story), 1) * 100}%"}
          ></span>
        </span>
      </span>
    </button>
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

  attr :counts, :map, required: true
  attr :target, :any, required: true

  # Issues: resolved against still open, with the open count beside it.
  defp issue_bar(assigns) do
    %{open: open, resolved: resolved} = assigns.counts
    total = open + resolved
    pct = if total == 0, do: 0, else: resolved / total * 100

    assigns =
      assign(assigns,
        open: open,
        resolved: resolved,
        pct: pct,
        tip: "Issues: #{open} open, #{resolved} resolved"
      )

    ~H"""
    <button
      type="button"
      phx-click="open_graph"
      phx-target={@target}
      data-test="issue-bar"
      data-open={@open}
      data-resolved={@resolved}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex w-full items-center gap-1.5"
    >
      <span class="flex h-2 w-full overflow-hidden rounded-full bg-error/60">
        <span class="h-full bg-success" style={"width: #{@pct}%"}></span>
      </span>
      <span class={[
        "shrink-0 font-mono text-[10px] tabular-nums",
        if(@open > 0, do: "text-error", else: "opacity-60")
      ]}>
        {@open}
      </span>
    </button>
    """
  end

  attr :counts, :any, required: true
  attr :target, :any, required: true

  # The components as one continuous bar: how much of their work is satisfied.
  defp component_bar(assigns) do
    {done, total} = assigns.counts || {0, 0}
    pct = if total == 0, do: 0, else: floor(done / total * 100)
    tip = "Components: #{done} of #{total} requirements satisfied"
    assigns = assign(assigns, done: done, total: total, pct: pct, tip: tip)

    ~H"""
    <button
      type="button"
      phx-click="open_graph"
      phx-target={@target}
      data-test="component-bar"
      data-done={@done}
      data-total={@total}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex w-full items-center gap-1.5"
    >
      <span class="flex h-2 w-full overflow-hidden rounded-full bg-base-content/15">
        <span class="h-full bg-primary" style={"width: #{@pct}%"}></span>
      </span>
      <span class="shrink-0 font-mono text-[10px] tabular-nums opacity-60">{@pct}%</span>
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
