defmodule CodeMySpecWeb.DevGraphLive do
  @moduledoc """
  Whether the requirement graph is keeping up, watched live rather than argued
  from logs. Dev only.

  - **Announcements arrive.** The feed is this project's `GraphInputs` topic:
    each announcement appears as published, with the observation id the
    consuming pass will carry. A write with no line here is a silent writer.
  - **They are consumed.** Each `{:graph_updated, _}` closes a pass over the
    announcements before it; the gap is the debounce window.
  - **The answer is then right.** "Serving stale" compares the served rows and
    edges with an in-memory recompute (`Requirements.served_vs_recomputed/1`),
    on demand and on each pass. A set that does not empty names entities whose
    input moved with no announcement.
  - Side by side: per-checkout vantages, the durable mark backlog, writer
    guarantees, the event vocabulary, the last drain of each kind, the watcher,
    and which checkouts have a harness joined.

  Read-only: the stale diff reports and discards. A page that recomputed on
  being opened would manufacture the freshness it claims to observe.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.DevState
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Verification
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
     |> assign_watched()
     |> assign_vantages()
     |> assign_stale()}
  end

  @impl true
  def handle_event("select", %{"project" => id}, socket) do
    unsubscribe(socket.assigns.selected)
    selected = Enum.find(socket.assigns.projects, &(&1.id == id))
    subscribe(selected)

    {:noreply,
     socket
     |> assign(selected: selected, feed: [])
     |> assign_vantages()
     |> assign_report()
     |> assign_watched()
     |> assign_stale()}
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
    {:noreply, socket |> close_pass() |> assign_report() |> assign_vantages() |> assign_stale()}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, socket |> assign_report() |> assign_watched() |> assign_vantages()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp record(socket, {kind, obs}) do
    entry = %{kind: kind, obs: obs, at: DateTime.utc_now(), consumed: []}
    update(socket, :feed, &Enum.take([entry | &1], @feed_limit))
  end

  # Which announcements this pass answered. Not carried on the message
  # (`{:graph_updated, id}` says only that something moved), so attributed by the
  # watcher's rule: a pass consumes everything announced before it. A pass with
  # nothing pending had its marks consumed by a `settle` elsewhere.
  defp close_pass(socket) do
    {pending, settled} =
      Enum.split_while(socket.assigns.feed, &(&1.kind == :announced and &1.consumed == []))

    entry = %{
      kind: :recomputed,
      obs: nil,
      at: DateTime.utc_now(),
      consumed: Enum.map(pending, & &1.obs) |> Enum.reject(&is_nil/1) |> Enum.reverse()
    }

    marked = Enum.map(pending, &Map.put(&1, :consumed, [:done]))

    assign(socket, feed: Enum.take([entry | marked] ++ settled, @feed_limit))
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

  # Whether each checkout has a harness joined to this server. The harness is the
  # only file watcher, so a copy with none stops moving silently. Whether the OS
  # still delivers events is known only to the harness (`CmsHarness.Project.Watcher`).
  defp assign_watched(%{assigns: %{selected: nil}} = socket), do: assign(socket, watched: [])

  defp assign_watched(%{assigns: %{selected: project}} = socket) do
    assign(socket,
      watched:
        project
        |> scope_of()
        |> CodeMySpec.WorkingCopies.list_harnesses()
        |> Enum.map(&%{root: &1.root, watched?: joined?(&1.id)})
    )
  end

  defp joined?(working_copy_id),
    do: Registry.lookup(HarnessRegistry, to_string(working_copy_id)) != []

  # Vantages side by side and the mark backlog: from a single vantage, other
  # checkouts frozen looks healthy, and a projector failing every drain shows only
  # as nothing changing.
  defp assign_vantages(%{assigns: %{selected: nil}} = socket),
    do:
      assign(socket,
        vantages: [],
        backlog: %{total: 0, groups: []},
        vocabulary: Requirements.event_vocabulary(),
        guarantees: Requirements.emit_guarantees(),
        drains_by_kind: [],
        drain: nil
      )

  defp assign_vantages(%{assigns: %{selected: project}} = socket) do
    scope = scope_of(project)

    assign(socket,
      vantages: Requirements.vantage_report(scope),
      backlog: Requirements.backlog_report(scope),
      vocabulary: Requirements.event_vocabulary(),
      guarantees: Requirements.emit_guarantees(),
      drain: DrainCost.last(project.id),
      drains_by_kind:
        Enum.reject(
          [
            DrainCost.last(project.id, :event),
            DrainCost.last(project.id, :reseed),
            DrainCost.last(project.id, :pass)
          ],
          &is_nil/1
        )
    )
  end

  defp assign_stale(%{assigns: %{selected: nil}} = socket), do: assign(socket, stale: nil)

  # Judged by recomputing from the domain now; the event path stamps no
  # fingerprints, so a fingerprint diff cannot judge its rows.
  defp assign_stale(%{assigns: %{selected: project}} = socket) do
    scope = scope_of(project)

    stale = {:recomputed, Requirements.served_vs_recomputed(scope)}
    assign(socket, stale: stale, stale_at: DateTime.utc_now())
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

      <form id="dev-graph-project-form" phx-change="select" class="flex items-center gap-2">
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

          <div :if={match?({:recomputed, _}, @stale)} data-test="recomputed" class="space-y-1">
            <p :if={recomputed_clean?(@stale)} class="text-sm text-success">
              Nothing. Every entity's inputs, recomputed now, agree with the rows being served
              ({elem(@stale, 1).served} rows, {elem(@stale, 1).served_edges} edges).
            </p>
            <p :if={not recomputed_clean?(@stale)} class="text-sm text-error">
              Recomputed now, the graph differs from what is served — rows not served {elem(@stale, 1).missing}, served but not recomputed {elem(
                @stale,
                1
              ).extra},
              disagreeing {elem(@stale, 1).disagree}; edges not served {elem(@stale, 1).edges_missing}, served but not recomputed {elem(
                @stale,
                1
              ).edges_extra}; offered-work differences {elem(@stale, 1).actionable_disagree}.
            </p>
            <p class="text-xs opacity-70">
              The event path serves this project. It settles rows from observations and
              stamps no fingerprint, so the rows are judged by recomputing every entity from
              its inputs, in memory, and comparing; nothing is written. A difference that
              does not clear on the next drain is an observation nothing applied.
            </p>
            <ul class="text-xs font-mono space-y-0.5">
              <li :for={line <- Enum.take(elem(@stale, 1).sample, 30)}>{line}</li>
            </ul>
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
            Checkouts — {length(@vantages)} answering
          </h2>
          <p class="text-xs opacity-60">
            A verdict is a statement about one checkout, so this is ten parallel answers rather
            than one. From any single vantage a stuck checkout looks exactly like a healthy
            graph; the <em>spread</em> between newest stamps is what says otherwise.
          </p>
          <table class="table table-xs">
            <thead>
              <tr>
                <th>checkout</th>
                <th class="text-right">rows</th>
                <th>newest</th>
                <th>oldest</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={v <- @vantages}>
                <td class={if is_nil(v.working_copy_id), do: "opacity-60", else: ""}>
                  {v.label}
                </td>
                <td class="text-right tabular-nums">{v.rows}</td>
                <td class="tabular-nums">{v.newest}</td>
                <td class="tabular-nums opacity-60">{v.oldest}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section data-test="emit-guarantees" class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Writer guarantees — {Enum.count(@guarantees, & &1.refused?)} of {length(@guarantees)} holding
          </h2>
          <p class="text-xs opacity-60">
            The two refusals that keep the vocabulary closed and the routing honest, asked
            rather than triggered. Both used to be enforced only by raising, which made them
            demonstrable only by attempting the thing they prevent — so neither was visible
            anywhere. These are answered by the same check the writer API applies.
          </p>
          <ul class="space-y-1 text-sm">
            <li
              :for={g <- @guarantees}
              data-test="guarantee"
              data-refused={to_string(g.refused?)}
              class="flex flex-wrap items-baseline gap-2"
            >
              <span class={if g.refused?, do: "text-success", else: "text-error font-semibold"}>
                {if g.refused?, do: "refused", else: "ACCEPTED"}
              </span>
              <span>{g.claim}</span>
              <span class="opacity-50 font-mono text-xs">({g.probe})</span>
              <span :if={g.because} class="w-full text-xs opacity-60 pl-4">{g.because}</span>
            </li>
          </ul>
        </section>

        <section
          data-test="event-vocabulary"
          data-declared={length(@vocabulary)}
          data-falls-back={Enum.count(@vocabulary, &(not &1.applied))}
          class="space-y-2"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Event vocabulary — {Enum.count(@vocabulary, & &1.applied)} of {length(@vocabulary)} applied
          </h2>
          <p class="text-xs opacity-60">
            The closed list of things that can move the graph. A writer cannot emit a kind
            that is not here, which is what makes this answerable at all — and each one is
            either applied by a handler or recomputed from the entities it names.
            Falling back is slower, never wrong; what it must not be is invisible.
          </p>
          <div class="flex flex-wrap gap-2">
            <span
              :for={entry <- @vocabulary}
              data-test="vocabulary-kind"
              data-kind={entry.kind}
              data-applied={to_string(entry.applied)}
              class={[
                "badge badge-sm font-mono",
                if(entry.applied, do: "badge-success badge-outline", else: "badge-ghost")
              ]}
            >
              {entry.kind}{if entry.applied, do: "", else: " — recomputes"}
            </span>
          </div>
        </section>

        <section data-test="backlog" data-pending={@backlog.total} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Backlog — {@backlog.total} pending
          </h2>
          <p :if={@backlog.total == 0} class="text-xs opacity-60">
            Nothing queued. Marks are durable so a crash cannot lose them, which means a
            number that grows here is drains failing, and a number that sits still is drains
            falling behind.
          </p>
          <table :if={@backlog.total > 0} class="table table-xs">
            <thead>
              <tr>
                <th>writer</th>
                <th>kind</th>
                <th>scope</th>
                <th>checkout</th>
                <th class="text-right">pending</th>
                <th>oldest</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={g <- @backlog.groups}
                data-test="backlog-row"
                data-scope={g.entity_scope}
                data-source={g.source}
                data-copy={g.working_copy_id || "project-wide"}
              >
                <td>{g.source}</td>
                <td class="opacity-60">{g.kind || "invalidate"}</td>
                <td class={if g.entity_scope == "unknown", do: "text-warning", else: "opacity-60"}>
                  {g.entity_scope}
                </td>
                <td class="font-mono text-xs opacity-60">
                  {(g.working_copy_id && String.slice(g.working_copy_id, 0, 8)) || "project-wide"}
                </td>
                <td class="text-right tabular-nums">{g.count}</td>
                <td class="tabular-nums opacity-60">{g.oldest}</td>
              </tr>
            </tbody>
          </table>
          <p class="text-xs opacity-60">
            <code>unknown</code> scope is the expensive one: the writer could not say what it
            moved, so it is read as the whole project at every checkout.
          </p>
        </section>

        <section :if={@drain} data-test="last-drain" data-kind={@drain.kind} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Last drain of each kind
          </h2>
          <p class="text-xs opacity-60">
            Both kinds run on the same settle, so the last of <em>each</em>
            is kept rather than
            the last overall — a single slot holds whichever finished second and the comparison
            this whole feature rests on is lost. <code>event</code>
            is a projection maintained from handlers; <code>pass</code>
            is a whole recompute. Counts cover the projection block, excluding queue
            consumption and notifications. Handled and fallback counts count marks per
            checkout, not nodes; seeding and topology work are additional. The latest
            drains may represent different observations and are not a paired benchmark.
          </p>
          <div
            :for={d <- @drains_by_kind}
            data-test="drain"
            data-kind={d.kind}
            class="flex flex-wrap items-baseline gap-4 text-sm tabular-nums"
          >
            <span class="font-mono w-14 opacity-70">{d.kind}</span>
            <span :if={d.raised} data-test="drain-failed" class="text-error">
              Failed — partial cost
            </span>
            <span data-test="drain-queries">{d.queries} queries</span>
            <span data-test="drain-rows-written">{d.rows_written} rows written</span>
            <span data-test="drain-edges-rebuilt">{d[:edges_rebuilt] || 0} edge rebuilds</span>
            <span data-test="drain-project-preloads">
              {d[:project_preloads] || 0} project preloads
            </span>
            <span data-test="drain-projection-writes">
              {d[:projection_writes] || 0} projection writes
            </span>
            <span data-test="drain-vantages">{d.vantages || "—"} checkouts</span>
            <span data-test="drain-observations" class="opacity-60">
              {d.observations || "unknown"} observations
            </span>
            <span data-test="drain-handled" class="opacity-60">
              handled mark/checkouts {d.handled || "unknown"}
            </span>
            <span
              data-test="drain-recomputed"
              class={if (d.recomputed || 0) > 0, do: "text-warning", else: "opacity-60"}
            >
              fallback mark/checkouts {d.recomputed || "unknown"}
            </span>
            <span class="opacity-40">
              {d.duration_ms}ms (db {d[:db_ms] || 0}, queued {d[:queued_ms] || 0})
            </span>
          </div>
          <p class="text-xs opacity-60">
            Queries and rows are the cost; milliseconds measure the machine. The same
            seventeen-query drain has been seen at 4ms and 18ms per query inside one minute
            under load, while the counts did not move.
          </p>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Watcher {if @report.watcher && @report.watcher.pending, do: "— recomputing", else: ""}
          </h2>
          <div :if={is_nil(@report.watcher)} class="text-sm text-error">
            Nothing is watching this project. Reads serve rows, so the graph will not move
            until something starts a watcher — and <code>settle/1</code>
            answers <code>:ok</code>
            either way, which is why this is worth saying out loud.
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
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            Harness
          </h2>
          <p class="text-xs opacity-60">
            Each checkout's harness is what carries filesystem changes after boot: it
            watches, sends the manifest, and the reconcile announces. A checkout whose
            harness has not joined since this server started cannot announce, and this
            page would then show a quiet feed and a stale set that never empties.
            Whether the OS is still delivering events to it is known to the harness,
            not here.
          </p>
          <ul class="text-xs font-mono space-y-0.5">
            <li :for={w <- @watched} class="flex gap-3">
              <span class={if w.watched?, do: "text-success", else: "text-error"}>
                {if w.watched?, do: "joined", else: "NOT joined"}
              </span>
              <span class="opacity-70">{w.root || "(no root reported)"}</span>
            </li>
            <li :if={@watched == []} class="opacity-70">No checkouts on this project.</li>
          </ul>
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
              <span :if={e.kind == :recomputed and e.consumed != []} class="opacity-70">
                consumed {Enum.join(e.consumed, ",")}
              </span>
              <span :if={e.kind == :recomputed and e.consumed == []} class="opacity-40">
                consumed nothing pending — settled elsewhere
              </span>
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
              <tr>
                <th>Checkout</th>
                <th class="text-right">Rows</th>
                <th>Newest row</th>
              </tr>
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

  defp recomputed_clean?({:recomputed, report}),
    do: Verification.clean?(report)

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
