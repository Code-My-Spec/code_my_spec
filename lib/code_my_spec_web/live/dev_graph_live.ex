defmodule CodeMySpecWeb.DevGraphLive do
  @moduledoc """
  Whether the requirement graph is actually keeping up, watched live rather
  than argued from logs.

  Three things have to be true for "incremental sync works", and each of them
  used to be checked by grepping a file and believing the result.

  **Announcements arrive.** A writer that changes a graph input says so. The
  event feed here is this project's own `GraphInputs` topic, so an announcement
  appears the instant it is published, with the observation id that the
  recompute consuming it will carry. A write you can see happen with no line in
  this feed is a silent writer, which is the defect this whole design removes.

  **They are consumed.** A pass follows, and the feed shows that too. The gap
  between an announcement and the pass answering it is the debounce window made
  visible.

  **The answer is then right.** That is the stale panel, and it is the only one
  that can be trusted on its own. It runs the full per-entity fingerprint diff
  — every entity's inputs rebuilt and compared against what its rows are
  stamped with — and reports what is being served stale, changing nothing. It
  re-runs whenever a pass lands, so the useful thing to watch is the set
  emptying as the recompute consumes what was announced.

  A set that does not empty is the finding. It means an input moved and nothing
  said so, and it names the entities rather than leaving it to be inferred.

  ## Why the stale query is here and not only in the log

  `graph_stale_read_log` makes every read do this diff and write it to the log.
  That is the right shape for a dev server nobody is looking at, and the wrong
  one for someone actually investigating: it costs the expensive half of a
  recompute on every read, and it answers in a file rather than in front of
  you. Here it is run on demand and on each pass, by one reader, against one
  project.

  ## Read-only

  Nothing on this page computes the graph. The stale diff is expensive and
  deliberately so, but it reports and discards — a page that recomputed on
  being opened would manufacture the freshness it claims to observe, which is
  exactly the behaviour this change removed from the read path.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.DevState
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  # Long, because events do the work. This only catches what has no
  # announcement behind it — a watcher dying, a vantage appearing.
  @refresh_ms 15_000
  @feed_limit 30

  @impl true
  def mount(_params, _session, socket) do
    projects = projects()
    selected = List.first(projects)

    if connected?(socket) do
      schedule_tick()
      subscribe(selected)
    end

    {:ok,
     socket
     |> assign(projects: projects, selected: selected, feed: [], checking?: false)
     |> assign_report()
     |> assign_stale()}
  end

  @impl true
  def handle_event("select", %{"project" => id}, socket) do
    unsubscribe(socket.assigns.selected)
    selected = Enum.find(socket.assigns.projects, &(&1.id == id))
    subscribe(selected)

    {:noreply,
     socket |> assign(selected: selected, feed: []) |> assign_report() |> assign_stale()}
  end

  def handle_event("recheck", _params, socket), do: {:noreply, assign_stale(socket)}

  # An announcement, as it is published. `obs` is the id the pass that consumes
  # it will carry, which is what ties the two halves of the feed together.
  @impl true
  def handle_info({:graph_inputs_changed, _project_id, obs}, socket) do
    {:noreply, record(socket, {:announced, obs})}
  end

  def handle_info({:graph_inputs_changed, _project_id}, socket) do
    {:noreply, record(socket, {:announced, nil})}
  end

  # A pass landed. Re-read the rows and re-run the diff, because this is the
  # moment the answer is supposed to have become right.
  def handle_info({:graph_updated, _project_id}, socket) do
    {:noreply, socket |> record({:recomputed, nil}) |> assign_report() |> assign_stale()}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_report(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp record(socket, {kind, obs}) do
    entry = %{kind: kind, obs: obs, at: DateTime.utc_now()}
    update(socket, :feed, &Enum.take([entry | &1], @feed_limit))
  end

  defp subscribe(%{id: id}), do: GraphInputs.subscribe(id)
  defp subscribe(_none), do: :ok

  defp unsubscribe(%{id: id}),
    do: Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, GraphInputs.topic(id))

  defp unsubscribe(_none), do: :ok

  defp projects do
    DevState.report().projects
    |> Enum.map(&%{id: &1.project_id, name: &1.name})
    |> Enum.sort_by(& &1.name)
  end

  defp scope_of(%{id: id}), do: %Scope{active_project_id: id}

  defp assign_report(%{assigns: %{selected: nil}} = socket), do: assign(socket, report: nil)

  defp assign_report(%{assigns: %{selected: project}} = socket),
    do: assign(socket, report: Requirements.incremental_report(scope_of(project)))

  defp assign_stale(%{assigns: %{selected: nil}} = socket), do: assign(socket, stale: nil)

  defp assign_stale(%{assigns: %{selected: project}} = socket) do
    assign(socket,
      stale: Requirements.stale_entities_report(scope_of(project)),
      stale_at: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="space-y-1">
        <h1 class="text-xl font-semibold">Incremental sync</h1>
        <p class="text-sm opacity-70">
          A writer announces, a pass consumes it, and the answer becomes right. All three
          are visible here. Nothing on this page recomputes the graph.
        </p>
      </header>

      <form phx-change="select" class="flex items-center gap-2">
        <label for="project" class="text-sm opacity-70">Project</label>
        <select id="project" name="project" class="select select-sm select-bordered">
          <option :for={p <- @projects} value={p.id} selected={@selected && p.id == @selected.id}>
            {p.name}
          </option>
        </select>
      </form>

      <p :if={is_nil(@report)} class="text-sm opacity-70">No project to report on.</p>

      <div :if={@report} class="space-y-6">
        <section class="space-y-2">
          <div class="flex items-baseline justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
              Serving stale
            </h2>
            <div class="flex items-center gap-3 text-xs opacity-60">
              <span :if={assigns[:stale_at]}>checked {@stale_at}</span>
              <button phx-click="recheck" class="btn btn-xs">Re-check</button>
            </div>
          </div>

          <div :if={@stale == {:partial, []}} class="text-sm text-success">
            Nothing. Every entity's inputs agree with the rows being served.
          </div>

          <div :if={match?({:all, _}, @stale)} class="space-y-1">
            <p class="text-sm text-error">Every entity reads stale.</p>
            <p class="text-xs opacity-70">
              {elem(@stale, 1)} — usually a shared input moving rather than every entity
              changing.
            </p>
          </div>

          <div :if={stale_list(@stale) != []} class="space-y-1">
            <p class="text-sm text-error">
              {length(stale_list(@stale))} entity(ies) are being served from rows their own
              inputs have moved past.
            </p>
            <p class="text-xs opacity-70">
              If this does not empty after the next pass, something wrote without announcing
              it — these are the entities to trace back to a writer.
            </p>
            <ul class="text-xs font-mono grid grid-cols-3 gap-x-4">
              <li :for={{type, id} <- Enum.take(stale_list(@stale), 30)}>{type}:{id}</li>
            </ul>
          </div>

          <p :if={match?({:error, _}, @stale)} class="text-sm opacity-70">
            Could not read this project: {inspect(elem(@stale, 1))}
          </p>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Watcher {if @report.watcher && @report.watcher.pending, do: "— recomputing", else: ""}
          </h2>
          <div :if={is_nil(@report.watcher)} class="text-sm text-error">
            Nothing is watching this project. Reads serve rows, so the graph will not move
            until something starts a watcher — and <code>settle/1</code> answers
            <code>:ok</code> either way, which is why this is worth saying out loud.
          </div>
          <dl :if={@report.watcher} class="grid grid-cols-3 gap-4 text-sm">
            <div>
              <dt class="opacity-60">Pass pending</dt>
              <dd class={if @report.watcher.pending, do: "text-warning", else: ""}>
                {if @report.watcher.pending, do: "yes — a pass is queued", else: "no"}
              </dd>
            </div>
            <div>
              <dt class="opacity-60">Last recompute</dt>
              <dd class="tabular-nums">{@report.watcher.last_recompute || "never"}</dd>
            </div>
            <div>
              <dt class="opacity-60">Last error</dt>
              <dd class={if @report.watcher.last_error, do: "text-error", else: ""}>
                {(@report.watcher.last_error && @report.watcher.last_error.message) || "none"}
              </dd>
            </div>
          </dl>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Events</h2>
          <p :if={@feed == []} class="text-sm opacity-70">
            Nothing yet. Announcements and the passes answering them appear here as they
            happen — write something the graph is computed from and it should show up.
          </p>
          <ul :if={@feed != []} class="text-xs font-mono space-y-0.5">
            <li :for={e <- @feed} class="flex gap-3">
              <span class="opacity-60 tabular-nums">{Calendar.strftime(e.at, "%H:%M:%S")}</span>
              <span class={event_class(e.kind)}>{event_label(e.kind)}</span>
              <span :if={e.obs} class="opacity-70">obs={e.obs}</span>
            </li>
          </ul>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Passes — {@report.total_rows} rows
          </h2>
          <p :if={@report.passes == []} class="text-sm opacity-70">
            No rows carry a <code>checked_at</code>, so nothing has computed this project.
          </p>
          <table :if={@report.passes != []} class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th class="text-right">Rows</th>
                <th class="w-1/2">Share of project</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @report.passes}>
                <td class="tabular-nums">{p.at}</td>
                <td class="text-right tabular-nums">{p.rows}</td>
                <td>
                  <div class="flex items-center gap-2">
                    <div class="h-2 w-40 rounded bg-base-300">
                      <div
                        class={["h-2 rounded", bar_class(p.share)]}
                        style={"width: #{bar_width(p.share)}%"}
                      >
                      </div>
                    </div>
                    <span class="tabular-nums text-xs opacity-70">{percent(p.share)}</span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Vantages</h2>
          <table class="table table-sm">
            <thead>
              <tr><th>Checkout</th><th class="text-right">Rows</th><th>Newest row</th></tr>
            </thead>
            <tbody>
              <tr :for={v <- @report.vantages}>
                <td><code>{vantage_label(v.vantage)}</code></td>
                <td class="text-right tabular-nums">{v.rows}</td>
                <td class="tabular-nums">{v.newest || "—"}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </div>
    """
  end

  defp stale_list({:partial, entities}), do: entities
  defp stale_list(_other), do: []

  defp event_label(:announced), do: "announced"
  defp event_label(:recomputed), do: "recomputed"

  defp event_class(:announced), do: "text-warning"
  defp event_class(:recomputed), do: "text-success"

  defp vantage_label(nil), do: "(unscoped)"
  defp vantage_label(id), do: String.slice(id, 0, 8)

  # A pass is judged against the whole project, so a full rebuild fills the bar
  # and three rows barely mark it. The floor keeps a real pass visible rather
  # than rounding it away to nothing.
  defp bar_width(share), do: max(share * 100, 1.5)

  defp bar_class(share) when share >= 0.5, do: "bg-error"
  defp bar_class(share) when share >= 0.1, do: "bg-warning"
  defp bar_class(_share), do: "bg-success"

  defp percent(share) when share >= 0.01,
    do: :erlang.float_to_binary(share * 100, decimals: 0) <> "%"

  defp percent(share), do: :erlang.float_to_binary(share * 100, decimals: 1) <> "%"
end
