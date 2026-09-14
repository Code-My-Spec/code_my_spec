defmodule CodeMySpecWeb.DevGraphLive do
  @moduledoc """
  Whether the requirement graph is actually recomputing incrementally, read off
  the rows rather than argued from logs.

  The claim this page exists to settle is "incremental sync works". Until it
  existed, the evidence was log lines — `recomputed 63 of 2078 requirements` —
  scrolled past in a file, and anyone who wanted to know whether the last hour
  had been incremental had to grep and add up. Worse, those lines are each
  pass's own account of itself: a pass that recomputed everything and a pass
  that recomputed three things both report honestly, and nothing puts them side
  by side.

  The rows answer it directly, and they are the thing being claimed about.
  Every pass stamps `checked_at` on exactly the entities it recomputed and
  leaves the rest alone — that is the whole of what "incremental" means here —
  so a distinct `checked_at` *is* a pass, and its size is the pass's size. A
  column of small numbers is the claim; a column of full-height ones is the
  claim failing, against a named pass rather than a feeling.

  ## What each panel is for

  `Watcher` is whether anything is maintaining this project at all. `settle/1`
  answers `:ok` when nothing is watching, so a project with no watcher looks
  exactly like a project where nothing has happened — this is the only place
  that distinction is visible. `last_error` is here because a recompute that
  fails leaves every reader served the last good answer: correct-looking, and
  frozen.

  `Vantages` is rows per working copy. Rows are keyed per checkout, and a
  watcher maintaining one checkout's row-space while leaving the others frozen
  is a real failure that nothing surfaced when it happened — a vantage sitting
  at an old `newest` while its neighbours advance is what that looks like.

  `Passes` is the proof.

  ## Live, and read-only

  Subscribes to the project's own `GraphInputs` topic, so a pass appearing is
  the page reacting to the same announcement the watcher did rather than to a
  poll. The timer is a fallback for the panels that have no event behind them.

  Nothing here computes. Every number is read from rows that already exist,
  because a page that recomputed on being opened would manufacture the
  freshness it reports — which is precisely the behaviour this whole change
  removed from the read path, and it would be an embarrassing place to
  reintroduce it.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.DevState
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  # Long, because the events do the work. This only catches what has no
  # announcement behind it — a watcher dying, a vantage appearing.
  @refresh_ms 10_000

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
     |> assign(projects: projects, selected: selected, refresh_ms: @refresh_ms)
     |> assign_report()}
  end

  @impl true
  def handle_event("select", %{"project" => id}, socket) do
    unsubscribe(socket.assigns.selected)
    selected = Enum.find(socket.assigns.projects, &(&1.id == id))
    subscribe(selected)

    {:noreply, socket |> assign(selected: selected) |> assign_report()}
  end

  @impl true
  def handle_info({:graph_updated, _project_id}, socket), do: {:noreply, assign_report(socket)}

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, assign_report(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp subscribe(%{id: id}), do: GraphInputs.subscribe(id)
  defp subscribe(_none), do: :ok

  defp unsubscribe(%{id: id}), do: Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, GraphInputs.topic(id))
  defp unsubscribe(_none), do: :ok

  defp projects do
    DevState.report().projects
    |> Enum.map(&%{id: &1.project_id, name: &1.name})
    |> Enum.sort_by(& &1.name)
  end

  defp assign_report(%{assigns: %{selected: nil}} = socket), do: assign(socket, report: nil)

  defp assign_report(%{assigns: %{selected: project}} = socket) do
    assign(socket, report: Requirements.incremental_report(%Scope{active_project_id: project.id}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="space-y-1">
        <h1 class="text-xl font-semibold">Incremental sync</h1>
        <p class="text-sm opacity-70">
          Every pass stamps <code>checked_at</code> on exactly what it recomputed, so a
          distinct stamp is a pass and its size is the pass's size. Read from rows;
          nothing here recomputes.
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
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Watcher</h2>
          <div :if={is_nil(@report.watcher)} class="text-sm text-error">
            Nothing is watching this project. Reads serve rows and compute nothing, so the
            graph will not move until something starts a watcher — and
            <code>settle/1</code> answers <code>:ok</code> either way, which is why this is
            worth saying out loud.
          </div>
          <dl :if={@report.watcher} class="grid grid-cols-3 gap-4 text-sm">
            <div>
              <dt class="opacity-60">Pass pending</dt>
              <dd>{if @report.watcher.pending, do: "yes", else: "no"}</dd>
            </div>
            <div>
              <dt class="opacity-60">Last recompute</dt>
              <dd>{@report.watcher.last_recompute || "never"}</dd>
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
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Vantages — {@report.total_rows} rows
          </h2>
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

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Passes — newest first
          </h2>
          <p :if={@report.passes == []} class="text-sm opacity-70">
            No rows carry a <code>checked_at</code> yet, so nothing has computed this project.
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

        <section class="text-sm">
          <span class="opacity-60">Stale-read logging</span>
          <span :if={@report.stale_read_log} class="ml-2">
            on — every read reports the entities it is serving stale, by id, in the log
          </span>
          <span :if={!@report.stale_read_log} class="ml-2 opacity-70">
            off — <code>config :code_my_spec, graph_stale_read_log: true</code> to find writers
            that change something without announcing it
          </span>
        </section>
      </div>
    </div>
    """
  end

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
