defmodule CodeMySpecWeb.DevGraphLive do
  @moduledoc """
  Whether the requirement graph is actually keeping up, watched live rather
  than argued from logs.

  Four things have to be true for "incremental sync works", and each of them
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

  **And somebody is told.** Fresh rows are where this machinery's job ends and
  where the point of it does not: the observable feature is an idle agent
  learning that work appeared. "What the last pass caused" is that link —
  what became actionable that was not before, and when a wake last went out.
  It is the only panel whose quiet answer is usually the right one, so it says
  "nothing new" rather than going blank: a pass that woke nobody because
  nothing appeared and a pass that woke nobody because the wake is broken look
  identical everywhere else.

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
  alias CodeMySpec.ProjectSync.FileWatcherServer
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
     |> assign_watched()
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
    {:noreply, socket |> close_pass() |> assign_report() |> assign_stale()}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, socket |> assign_report() |> assign_watched()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :tick, @refresh_ms)

  defp record(socket, {kind, obs}) do
    entry = %{kind: kind, obs: obs, at: DateTime.utc_now(), consumed: []}
    update(socket, :feed, &Enum.take([entry | &1], @feed_limit))
  end

  # Which announcements this pass answered.
  #
  # Not carried on the message, and deliberately: criterion 3355 pins
  # `{:graph_updated, project_id}` to saying only that something moved, so a
  # subscriber cannot be handed the observation ids. The attribution is instead
  # made the same way the watcher makes it — a pass consumes everything
  # announced before it and nothing after — which is the actual rule rather than
  # a second copy of it shipped over PubSub.
  #
  # The consequence worth knowing when reading this feed: a pass that lands
  # against an empty pending set is one whose observations were consumed by a
  # `settle/1` from somewhere else, not a pass that ran for no reason.
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

  # Whether this project's checkouts are on the file watcher at all.
  #
  # The end state this design is aimed at is "scan the filesystem at boot, let
  # events carry it after" — which is only true while the events are arriving.
  # A watcher that is not watching a root, or a stream that has gone quiet,
  # turns into a project that stops moving and says nothing, which is the exact
  # failure `GraphWatcher` exists to end arriving through a different door.
  #
  # Server-side this can only answer "is the root registered". Whether the OS
  # is still delivering events is known to the harness process and not here —
  # `CmsHarness.Project.Watcher` is what notices a stream going silent. So this
  # is the cheaper half of the question, and it is worth having because the
  # expensive half is invisible from this side and the cheap half is often the
  # answer.
  defp assign_watched(%{assigns: %{selected: nil}} = socket), do: assign(socket, watched: [])

  defp assign_watched(%{assigns: %{selected: project}} = socket) do
    roots = CodeMySpec.WorkingCopies.list_harnesses(scope_of(project)) |> Enum.map(& &1.root)
    watched = safe_watched_dirs()

    assign(socket,
      watched:
        Enum.map(roots, fn root ->
          %{root: root, watched?: root != nil and Enum.any?(watched, &(&1 == root))}
        end)
    )
  end

  defp safe_watched_dirs do
    FileWatcherServer.watched_dirs()
  catch
    :exit, _ -> []
  end

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

        <section :if={@report.watcher} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            What the last pass caused
          </h2>
          <p class="text-xs opacity-60">
            The end of the chain, and the half that a fresh row count cannot show. A pass
            wakes the roles for work that <em>appeared</em> — the difference between its
            actionable set and the previous pass's — so "recomputed, appeared nothing,
            woke nobody" is the correct and common answer, and is not the same as a pass
            that found work and told no one.
          </p>
          <dl class="grid grid-cols-3 gap-4 text-sm">
            <div>
              <dt class="opacity-60">Actionable now</dt>
              <dd class="tabular-nums">{@report.watcher.actionable || "no pass yet"}</dd>
            </div>
            <div>
              <dt class="opacity-60">Appeared on that pass</dt>
              <dd class="font-mono text-xs">
                {case @report.watcher.appeared do
                  nil -> "no pass yet"
                  [] -> "nothing new"
                  names -> Enum.join(names, ", ")
                end}
              </dd>
            </div>
            <div>
              <dt class="opacity-60">Last wake sent</dt>
              <dd class="tabular-nums">{@report.watcher.last_wake || "never"}</dd>
            </div>
          </dl>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
            File watcher
          </h2>
          <p class="text-xs opacity-60">
            Events are what carry filesystem changes after boot. A root that is not
            watched cannot announce, and this page would then show a quiet feed and a
            stale set that never empties. Whether the OS is still delivering events is
            known to the harness, not here.
          </p>
          <ul class="text-xs font-mono space-y-0.5">
            <li :for={w <- @watched} class="flex gap-3">
              <span class={if w.watched?, do: "text-success", else: "text-error"}>
                {if w.watched?, do: "watched", else: "NOT watched"}
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
