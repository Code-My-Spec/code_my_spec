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

  Every mark opens the graph page — a gate on its own requirement — and the
  button at the end opens the whole graph in a modal, computed off the
  LiveView process only when asked for.
  """

  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Requirements.Bands
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Requirements.PlainLanguage
  alias CodeMySpec.Requirements.RequirementDefinitionData

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

    socket = assign_new(socket, :graph_modal, fn -> nil end)

    if refresh? or not Map.has_key?(socket.assigns, :bands),
      do: {:ok, assign(socket, :bands, Bands.read(socket.assigns.scope))},
      else: {:ok, socket}
  end

  @impl true
  def handle_event("open_graph", _params, socket) do
    scope = socket.assigns.scope

    {:noreply,
     socket
     |> assign(:graph_modal, :loading)
     |> start_async(:graph, fn -> GraphProjector.project_graph_with_metrics(scope) end)}
  end

  def handle_event("close_graph", _params, socket),
    do: {:noreply, assign(socket, :graph_modal, nil)}

  @impl true
  def handle_async(
        :graph,
        {:ok, {data, _metrics}},
        %{assigns: %{graph_modal: :loading}} = socket
      ),
      do: {:noreply, assign(socket, :graph_modal, data)}

  def handle_async(:graph, {:exit, _reason}, %{assigns: %{graph_modal: :loading}} = socket),
    do: {:noreply, assign(socket, :graph_modal, :error)}

  def handle_async(:graph, _result, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    {early, late} = gates(assigns.bands, assigns.project)
    graph = ~p"/app/projects/#{assigns.project.id}/requirements/graph"
    assigns = assign(assigns, early: early, late: late, graph: graph)

    ~H"""
    <nav
      id={@id}
      data-test="project-timeline"
      aria-label="Where this project stands"
      class="border-b border-base-300 bg-base-200/50 px-4 py-2 lg:px-8"
    >
      <ol class="flex items-center gap-3">
        <li data-test="timeline-band" data-band="early" class="flex shrink-0 items-center gap-1">
          <.gate :for={step <- @early} step={step} />
        </li>
        <li data-test="timeline-band" data-band="pre_stories" class="min-w-0 flex-1">
          <.story_bar tally={@bands.pre_stories} label="Stories, before build" href={@graph} />
        </li>
        <li data-test="timeline-band" data-band="components" class="min-w-0 flex-[2]">
          <.component_bar counts={@bands.components} href={@graph} />
        </li>
        <li data-test="timeline-band" data-band="post_stories" class="min-w-0 flex-1">
          <.story_bar tally={@bands.post_stories} label="Stories, after build" href={@graph} />
        </li>
        <li data-test="timeline-band" data-band="late" class="flex shrink-0 items-center gap-1">
          <.gate :for={step <- @late} step={step} />
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
      <.graph_modal :if={@graph_modal} graph={@graph_modal} href={@graph} myself={@myself} />
    </nav>
    """
  end

  attr :graph, :any, required: true
  attr :href, :string, required: true
  attr :myself, :any, required: true

  # The whole graph over the conversation. The sigma element is drawn only once
  # the data is in, so its hook mounts with something to draw.
  defp graph_modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="graph-modal"
      phx-window-keydown="close_graph"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div class="modal-box w-11/12 max-w-6xl space-y-3">
        <button
          type="button"
          phx-click="close_graph"
          phx-target={@myself}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <h2 class="pr-8 text-lg font-semibold">Requirements graph</h2>
        <p :if={@graph == :loading} class="text-sm opacity-60">Computing the graph…</p>
        <p :if={@graph == :error} role="alert" class="text-sm text-error">
          The graph could not be computed. Try the full page.
        </p>
        <div :if={is_map(@graph)}>
          <div
            id="timeline-graph"
            phx-hook="SigmaGraph"
            phx-update="ignore"
            data-graph={Jason.encode!(@graph)}
            class="rounded-box border border-base-300 bg-base-200"
            style="position: relative; overflow: hidden; width: 100%; height: 65vh;"
          >
          </div>
          <div id="timeline-graph-debug"></div>
        </div>
        <div class="flex justify-end">
          <.link navigate={@href} data-test="graph-modal-open" class="btn btn-sm btn-ghost">
            Full page <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="close_graph"
        phx-target={@myself}
        aria-label="Close"
      ></button>
    </div>
    """
  end

  attr :step, :map, required: true

  # A project gate: a dot, or the pill naming it when it is the one the project
  # is on. Exactly one gate is current, always — an idle project is the
  # ordinary overnight state, and a strip marking nothing then reads as broken.
  defp gate(assigns) do
    ~H"""
    <span data-test="timeline-step" data-step={@step.name} data-state={@step.state}>
      <.link
        navigate={@step.path}
        title={@step.title}
        data-tip={@step.detail}
        class={["flex h-4 items-center", @step.detail && "tooltip tooltip-bottom"]}
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

  attr :tally, :map, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true

  # Stories as one bar, split by how far each has got: green done, pale green
  # partial, red with open issues, grey not started.
  defp story_bar(assigns) do
    total = assigns.tally |> Map.values() |> Enum.sum()
    assigns = assign(assigns, total: total, tip: story_tip(assigns.label, assigns.tally))

    ~H"""
    <.link
      navigate={@href}
      data-test="story-bar"
      data-done={@tally.done}
      data-partial={@tally.partial}
      data-issues={@tally.issues}
      data-none={@tally.none}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex h-2 w-full overflow-hidden rounded-full bg-base-content/15"
    >
      <span
        :for={{key, class} <- segments()}
        :if={@total > 0 and @tally[key] > 0}
        class={["h-full", class]}
        style={"width: #{@tally[key] / @total * 100}%"}
      ></span>
    </.link>
    """
  end

  defp segments,
    do: [done: "bg-success", partial: "bg-success/40", issues: "bg-error", none: ""]

  defp story_tip(label, tally),
    do:
      "#{label}: #{tally.done} done · #{tally.partial} partial · #{tally.issues} with issues · " <>
        "#{tally.none} not started"

  attr :counts, :any, required: true
  attr :href, :string, required: true

  # The components as one continuous bar: how much of their work is satisfied.
  defp component_bar(assigns) do
    {done, total} = assigns.counts || {0, 0}
    pct = if total == 0, do: 0, else: floor(done / total * 100)
    tip = "Components: #{done} of #{total} requirements satisfied"
    assigns = assign(assigns, done: done, total: total, pct: pct, tip: tip)

    ~H"""
    <.link
      navigate={@href}
      data-test="component-bar"
      data-done={@done}
      data-total={@total}
      data-tip={@tip}
      aria-label={@tip}
      class="tooltip tooltip-bottom flex items-center gap-1.5"
    >
      <span class="flex h-2 w-full overflow-hidden rounded-full bg-base-content/15">
        <span class="h-full bg-primary" style={"width: #{@pct}%"}></span>
      </span>
      <span class="shrink-0 font-mono text-[10px] tabular-nums opacity-60">{@pct}%</span>
    </.link>
    """
  end

  # The gates in template order, split where stories join, each with its state.
  defp gates(bands, project) do
    names = Enum.map(RequirementDefinitionData.project_graph(), & &1.name)
    current = Enum.find(names, List.last(names), &(not MapSet.member?(bands.satisfied, &1)))

    names
    |> Enum.map(&step(&1, bands.satisfied, current, project))
    |> Enum.split_with(&(not MapSet.member?(bands.late_names, &1.name)))
  end

  defp step(name, satisfied, current, project) do
    meaning = PlainLanguage.fetch(name) || %{}

    %{
      name: name,
      title: Map.get(meaning, :title, String.replace(name, "_", " ")),
      abbrev: Map.get(meaning, :abbrev, name |> String.split("_") |> hd()),
      detail: Map.get(meaning, :detail),
      state: state_of(name, satisfied, current),
      path: ~p"/app/projects/#{project.id}/requirements/graph?#{[focus: name]}"
    }
  end

  defp state_of(name, _satisfied, name), do: "current"

  defp state_of(name, satisfied, _current),
    do: if(MapSet.member?(satisfied, name), do: "done", else: "todo")
end
