defmodule CodeMySpec.Requirements.ShadowProjector do
  @moduledoc """
  One process per project, turning invalidation marks into a second projection.

  The event-based replacement being built beside the fingerprint pass, so the
  two can be compared on the same traffic before either is retired. It writes
  `shadow_requirements` and decides nothing; `Shadow.diff/2` is what says
  whether it is ready to.

  ## No debounce, and that is the point

  `GraphWatcher` coalesces a burst into one pass because a fingerprint pass is
  whole-project: it preloads everything, hashes everything and rebuilds the
  project nodes whatever moved, so paying that per event would be ruinous and
  waiting two seconds is the cheaper mistake.

  None of that is true here. A mark names an entity, `RequirementGraph.compute_entity/4`
  computes that entity, and the cost is proportional to what actually moved. So
  there is no timer: a mark that arrives is handled. Marks still arrive in
  groups when this process is behind or was down, and they are handled one at a
  time when they do — `Invalidations.pending/1` returning several is a consumer
  catching up, not a window being drained.

  ## What a drain loads is decided before it loads anything

  `plan/2` reads the marks and picks one of two shapes, because what they claim
  decides what has to be read:

    * `:everything` — a writer could not say what it moved, or this projector
      has not seeded. Whole context, every entity. This is the pass the event
      path exists to replace, and it is what an un-narrowed writer costs.
    * `{:narrow, entities}` — every mark named something. One narrow load per
      entity — `load_story/3`, `load_component_family/3` or `load_project/2` —
      and `Preloader.load/1` is never called.

  That last shape is the point of the whole exercise, and it inverts the
  premise `load/1` was built on. The story delegates take a scope and a story
  and query per story — "304 queries inside one graph computation" on a project
  with 76 ready stories — so batching them into `@delegated_tables` is what made
  a whole-project pass affordable. For one story the N+1 *is* the narrow load:
  four per-story queries against fifteen project-wide ones to avoid them.

  ## Failure is loud and nothing is dropped

  A drain that raises leaves its marks in place — `consume/1` runs only after
  the writes — so the next event retries them. A projector that cannot keep up
  or keeps failing shows as a growing `pending` count, which is the honest
  signal and the one an in-memory dirty set could never give.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Configurations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Edge
  alias CodeMySpec.Requirements.Freshness
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Invalidation
  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Shadow
  alias CodeMySpec.Users.Scope

  # -- Client --

  def start_link({project_id, scope}) do
    GenServer.start_link(__MODULE__, {project_id, scope}, name: via(project_id))
  end

  def via(project_id),
    do: {:via, Registry, {CodeMySpec.Requirements.Registry, {project_id, :shadow}}}

  @doc """
  Project this project's marks, if nothing is projecting them yet.

  Started beside `GraphWatcher` and refused outright when the experiment is
  off, so turning the flag off stops the work rather than merely ignoring it.
  """
  @spec ensure_projecting(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_projecting(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_projecting(%Scope{active_project_id: project_id} = scope) do
    if Shadow.enabled?() do
      case DynamicSupervisor.start_child(
             CodeMySpec.Requirements.WatcherSupervisor,
             {__MODULE__, {project_id, scope}}
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    else
      {:error, :disabled}
    end
  end

  @doc """
  Whether a projector is running for this project, and therefore whether
  anything is going to consume the marks besides the pass.

  `Invalidations.consume/1` is a delete, so the pass and a projector draining
  the same queue is a destructive read: whichever wins takes the marks and the
  other never sees them. The pass defers to a projector that exists — and only
  to one that exists, because deferring to an absent projector is how
  `e0729ea9` comes back: every writer inserting a mark and nothing deleting one.
  """
  @spec running?(Ecto.UUID.t() | nil) :: boolean()
  def running?(project_id) when is_binary(project_id) do
    Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :shadow}) != []
  end

  def running?(_no_project), do: false

  @doc """
  Handle everything pending now, before the caller compares.

  The diff reads both projections, so it has to be asked at a moment when the
  event path has been given its chance — otherwise every mark still in flight
  reports as a difference and the number says more about timing than about
  coverage.
  """
  @spec settle(Ecto.UUID.t() | nil, Enumerable.t()) :: :ok
  def settle(project_id, requested \\ [])

  def settle(project_id, requested) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :shadow}) do
      [{pid, _}] -> GenServer.call(pid, {:drain, requested}, 30_000)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def settle(_no_project, _requested), do: :ok

  # -- Server --

  @impl true
  def init({project_id, scope}) do
    GraphInputs.subscribe(project_id)

    # One whole-project computation on arrival, then maintain from events.
    #
    # Not an exception to "no batching" — it is the thing that makes the rest of
    # it possible. An accumulated projection has to start from a known state,
    # and a consumer that only ever applied deltas would hold a shadow that is
    # missing every entity nothing has touched since it started, permanently,
    # while reporting the gap as a coverage failure it cannot fix.
    #
    # It is also the shape the design called for: build the state of the graph
    # with one query up front, and the event handlers after it stay simple
    # because they never have to reconstruct what they did not see.
    #
    # Sent rather than done in `init/1`, because this blocks the supervisor and
    # a cold project is a whole graph.
    send(self(), :seed)

    {:ok,
     %{
       project_id: project_id,
       scope: scope,
       seeded: false,
       requested_vantages: MapSet.new(),
       # The four analyzer-freshness booleans, kept between drains. Project-wide
       # and computed from the whole checkout's files, so recomputing it per
       # narrow drain would reintroduce the read the narrow path exists to
       # avoid. Only a writer that touched files or an analyzer run can move it,
       # and every one of those records `:unknown`.
       analysis_fresh: %{},
       # The topology this projector last wrote edges for. Edges are a global
       # computation, so the cheap question is whether they can have moved at
       # all — `Freshness.topology/2` is the same hash the pass records, over
       # component ids, types, parents, dependencies and the story population.
       last_topology: %{},
       last_drain: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call({:drain, requested}, _from, state) do
    {:reply, :ok, state |> remember(requested) |> drain()}
  end

  @impl true
  def handle_info(:seed, state), do: {:noreply, drain(state)}

  def handle_info({:graph_inputs_changed, _project_id, _obs}, state),
    do: {:noreply, drain(state)}

  def handle_info({:graph_inputs_changed, _project_id}, state), do: {:noreply, drain(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # Nothing pending and already seeded is the common case and costs one query.
  #
  # Nothing pending and *not* seeded still computes: the marks say what has
  # moved since this process started, and on the first pass that is the wrong
  # question. It has to establish what is true before deltas mean anything.
  defp drain(state) do
    case {state.seeded, Invalidations.pending(state.project_id)} do
      {true, []} -> state
      {_seeded, marks} -> apply_marks(state, marks)
    end
  rescue
    error ->
      Logger.warning(
        "[ShadowProjector] #{state.project_id} left #{inspect(error.__struct__)} pending: " <>
          Exception.message(error)
      )

      %{state | last_error: %{at: DateTime.utc_now(), message: Exception.message(error)}}
  end

  # The vantages these marks are about — asked of the marks, not enumerated.
  #
  # A verdict is a statement about a checkout, so the graph is projected per
  # vantage and this process was settling whichever scope happened to start it,
  # leaving the rest to whatever wrote them last. Found by `shadow_test`'s
  # accepted-issue case, which settles one vantage and asserts on another.
  #
  # The fix is not to loop every vantage on every drain. A file sync happens in
  # one worktree and moves one checkout's answers; dragging the other eight
  # through a settle for it is the whole-project recompute this path exists to
  # avoid, wearing a different hat. So a mark records the copy it was written
  # from and this reads it back — `nil` means the writer's change is not about a
  # checkout (a story renamed, an issue accepted), which every vantage reads and
  # which is the only case that fans out.
  #
  # The two caches go with it. `analysis_fresh` is computed from a checkout's
  # own files and `last_topology` from what that checkout can see, so both are
  # per-vantage facts and a single slot silently answered one vantage's question
  # with another's.
  defp apply_marks(state, marks) do
    config = Configurations.get_or_create(state.scope)
    base_scope = state.scope

    # Events first, and only what is left over goes to a plan.
    #
    # A handled event writes the verdict it already knew — one row, no
    # recompute. A mark with no handler still names entities, so it falls
    # through to `plan/2` exactly as before. That is what lets handlers arrive
    # one requirement at a time instead of all at once: the projection is never
    # wrong in the meantime, only slower where a handler is missing.
    # `handled` and `recomputed` are the applied-versus-re-derived split, which
    # is what a cost reading has to say for either number to mean anything: a
    # drain that fell back is a pass wearing this label, and comparing it
    # against one that applied its events would be comparing two systems.
    state =
      DrainCost.measure(
        %{kind: :event, project_id: state.project_id, observations: length(marks)},
        fn ->
          vantages = vantages(state, marks)

          # Counted per vantage rather than accumulated, and `log_handled/2` is
          # asked per vantage too. "This handler change matched no row" is a
          # statement about one checkout, so summing the lists first lets a hit
          # in one worktree cover a miss in another — which is the class of bug
          # the whole shadow exists to catch.
          {state, handled, recomputed, kinds} =
            Enum.reduce(
              vantages,
              {state, 0, 0, %{}},
              &settle_vantage(&1, &2, marks, base_scope, config)
            )

          {%{state | scope: base_scope},
           %{
             handled: handled,
             recomputed: recomputed,
             vantages: length(vantages),
             kinds: kinds_line(kinds)
           }}
        end
      )

    # Only once the writes are done. A mark consumed before the work it asks
    # for is a mark that a crash turns into a permanently stale entity, which
    # is the failure the durable set exists to rule out.
    Invalidations.consume(marks)
    announce(state, marks)

    %{state | seeded: true, last_drain: DateTime.utc_now(), last_error: nil}
  end

  # What the pass does after it writes, done here when this is the writer that
  # counts. `GraphWatcher` broadcasts `{:graph_updated, project_id}` and asks
  # `Work.consider_project/2` whether anyone should be woken, both gated on
  # having consumed something — a pass that ran for nothing announces nothing.
  # The projector did neither, so a flip of `graph_event_is_source` would have
  # left every reader current and every agent asleep.
  #
  # Only while inverted. With both writers on and the pass the source, the pass
  # already does this for every observation; doing it here too would wake each
  # agent twice per event.
  defp announce(_state, []), do: :ok

  defp announce(state, _marks) do
    if Shadow.inverted?() do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        GraphInputs.topic(state.project_id),
        {:graph_updated, state.project_id}
      )

      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        Work.consider_project(state.scope, :graph_changed)
      end)
    end

    :ok
  end

  # What the marks say, widened to everything only when one of them cannot say.
  #
  # `nil` on a mark is a writer whose change is not about a checkout — a story
  # renamed, an issue accepted — which every checkout reads, so it is the one
  # case that fans out. That is the conservative reading rather than a gap, the
  # same meaning `entity_scope` gives an un-narrowed writer.
  #
  # The `nil` *vantage* is not the same thing and does not follow from the same
  # rule. It is the row-space a reader with no checkout is answered from, and
  # `Preloader.files_vantage/1` computes it from the project's default checkout
  # — so a file sync in that checkout moves it, and a sync in any other
  # worktree does not. `live_vantages/2` prepends `nil` unconditionally, which
  # is right for a reader asking what to compute and wrong here: it would drag
  # the browser's view through a settle for every worktree on the project.
  # The seed asks a different question, and it is the question `init/1` says it
  # asks: not "which checkouts did these marks move" but "what is true". With no
  # marks there is nothing to read a checkout off, so this answered the empty
  # list and the whole-project computation ran against no vantage at all.
  #
  # The cost of that is exactly what `init/1` warns about: a projector that only
  # ever applies deltas is permanently missing every entity nothing has touched
  # since it started, and reports the gap as a coverage failure it cannot fix.
  # Measured on dev, 2026-09-17 — nine verdicts wrong at three vantages, last
  # settled before two fixes that would have corrected them, surviving four
  # restarts of the process whose arrival was supposed to correct them.
  defp vantages(%{seeded: false} = state, _marks),
    do: Projection.live_vantages(state.scope, Projection.vantages(state.scope))

  defp vantages(state, marks) do
    requested = MapSet.to_list(state.requested_vantages)
    named = marks |> Enum.map(& &1.working_copy_id) |> Enum.uniq()

    if Enum.any?(named, &is_nil/1) do
      Projection.live_vantages(state.scope, Projection.vantages(state.scope))
    else
      keep_nil? = Preloader.files_vantage(state.scope) in named

      state.scope
      |> Projection.live_vantages(Enum.concat(named, requested))
      |> Enum.filter(&(keep_nil? or not is_nil(&1) or &1 in requested))
    end
  end

  # The vantages a reader has asked about, which is the half the pass had and
  # this did not.
  #
  # `GraphWatcher` folds `requested_vantages` into every pass, so a checkout
  # somebody read is considered even when no mark names it. Nothing told the
  # projector, so it settled only what marks named — and the two drifted for as
  # long as reads and writes pointed at different checkouts. Measured on dev
  # 2026-09-21: the `Harness` vantage was current on the pass side at 11:19:47
  # and 6h36m behind on this one, because a reader had asked the pass for it and
  # nothing had asked here.
  #
  # Not a recompute-on-read, which is what criterion 3423 forbids and what the
  # 348-computes/2.6s measurement was. The vantage is *considered*; a pass over
  # it recomputes only entities whose own inputs moved, which is nothing at all
  # when nothing moved.
  defp remember(state, requested) do
    %{state | requested_vantages: Enum.into(requested, state.requested_vantages)}
  end

  # Each event offered to its handler; anything without one handed back.
  #
  # `{:ok, changes}` with an empty list is a real answer — the event moved
  # nothing the graph reads — and is *not* the same as `:no_handler`, which says
  # we do not know and must re-derive. Collapsing the two would make an
  # uninteresting event silently skip work it owed.
  defp apply_handlers(state, marks) do
    {handled, rest} = split_handled(state, marks)

    # An invalidation beside an event this drain handled is that event's
    # fallback, and it has been superseded. Dropping it by observation id is
    # what stops a handled event *also* recomputing the entities it named —
    # which would have made the handler pure overhead rather than a saving.
    answered = MapSet.new(handled, fn {mark, _c, _w} -> mark.observation_id end)

    {handled,
     Enum.reject(rest, fn mark ->
       mark.observation_id != nil and MapSet.member?(answered, mark.observation_id)
     end)}
  end

  # One transaction for every sweep this event settles, rather than one each.
  #
  # Correctness first: an event moves a *set* of requirements, and a reader
  # landing between two of its sweeps sees `spec_file` settled against
  # `spec_valid`'s previous answer — a projection that is internally
  # inconsistent in a way neither sweep is. `Shadow.sweep/2` keeps its own
  # transaction for its two halves; Ecto joins a nested one to the outer, so
  # this replaces twenty `BEGIN`/`COMMIT` pairs with one and changes nothing
  # else.
  #
  # The lock hold that would normally argue against this is not there: sweeps
  # skip rows whose answer did not move, so the steady state locks nothing and
  # a real change locks only what it changed.
  # One settle per distinct kind, not one per mark.
  #
  # A handler is a function of current state: `Handlers.apply_event/3` takes the
  # kind and ignores the payload, reloads the profiles that kind dirties, and
  # settles every requirement they move across the whole population. Running it
  # twice in one drain reaches the same answer and pays for it twice.
  #
  # Marks arrive in bulk more often than the design assumed.
  # `Stories.mark_ready_stories_promoted/2` broadcasts per story, so one
  # promotion stamping 130 stories emitted 130 `story_changed` marks — and this
  # settled each of them: four profile loads and eleven sweeps apiece, with
  # `ArchitectureChecker.orphans/1` preloading every component's stories on
  # every pass through. That is the whole-project recompute the event path
  # exists to avoid, 130 times over, for one act.
  #
  # Every mark of a handled kind is still returned, because `apply_handlers/2`
  # drops fallback marks by observation id and needs all of them. Only the first
  # carries the changes, so `log_handled/2` counts the work once rather than
  # once per mark.
  defp split_handled(state, marks) do
    marks
    |> Enum.group_by(& &1.kind)
    |> Enum.reduce({[], []}, fn {_kind, kind_marks}, {handled, unhandled} ->
      case handler_result(state.scope, hd(kind_marks)) do
        {:ok, changes, sweeps} ->
          written = settle(state.scope, changes, sweeps)
          {attribute(kind_marks, changes, written) ++ handled, unhandled}

        :no_handler ->
          {handled, kind_marks ++ unhandled}
      end
    end)
  end

  # The work belongs to the drain, not to each mark that asked for it.
  defp attribute([first | rest], changes, written),
    do: [{first, changes, written} | Enum.map(rest, &{&1, [], []})]

  defp settle(scope, changes, sweeps) do
    {:ok, written} =
      Repo.transaction(fn ->
        written = Enum.map(changes, &write_change(scope, &1))
        Enum.each(sweeps, &Shadow.sweep(scope, &1))
        written
      end)

    written
  end

  defp handler_result(_scope, %Invalidation{kind: kind}) when kind in [nil, "invalidate"],
    do: :no_handler

  defp handler_result(scope, %Invalidation{kind: kind, payload: payload}),
    do: Handlers.apply_event(scope, kind, payload || %{})

  defp write_change(scope, change) do
    {:ok, count} = Shadow.put_verdict(scope, change)
    count
  end

  # A handler that wrote nothing matched no row, which means the event named an
  # entity this vantage has never projected. Worth a line, because a handler
  # silently writing nothing is precisely the failure that looks like success.
  # `unhandled == []` is "nothing left to re-derive", which is true of a drain
  # whose handlers covered everything — and of the seed, which has no marks at
  # all. Those are not the same, and collapsing them is what stopped the seed
  # seeding: `plan/2` still answers `:everything` for an unseeded projector, and
  # nothing ever asked it. So the guard is "no work to do", and a projector that
  # has not established what is true has work to do whatever its marks say.
  defp settle_vantage(vantage, {state, handled, recomputed, kinds}, marks, base_scope, config) do
    state = %{state | scope: %{base_scope | active_working_copy_id: vantage}}
    {applied, unhandled} = apply_handlers(state, marks)

    state =
      if unhandled == [] and state.seeded,
        do: state,
        else: run(plan(state, unhandled), state, config)

    log_handled(state, applied)

    {state, handled + length(applied), recomputed + length(unhandled),
     tally(kinds, applied, unhandled)}
  end

  # Which kinds this drain handled and which it fell back on, by mark count,
  # for the cost line. Queries are attributable to a kind only if the line
  # names the kinds; without this every 37-query drain read alike, and the
  # question "which event costs three profile loads" had no answer in the log.
  defp tally(kinds, applied, unhandled) do
    applied
    |> Enum.frequencies_by(fn {mark, _changes, _written} -> {:handled, kind_of(mark)} end)
    |> Map.merge(Enum.frequencies_by(unhandled, &{:recomputed, kind_of(&1)}))
    |> Map.merge(kinds, fn _key, a, b -> a + b end)
  end

  defp kind_of(%Invalidation{kind: kind}) when kind in [nil, "invalidate"], do: "invalidation"
  defp kind_of(%Invalidation{kind: kind}), do: kind

  defp kinds_line(kinds) when map_size(kinds) == 0, do: "none"

  defp kinds_line(kinds) do
    Enum.map_join(Enum.sort(kinds), " ", fn {{side, kind}, n} -> "#{side}:#{kind}×#{n}" end)
  end

  defp log_handled(state, []), do: state

  defp log_handled(state, handled) do
    changes = handled |> Enum.flat_map(fn {_m, c, _w} -> c end) |> length()
    rows = handled |> Enum.flat_map(fn {_m, _c, w} -> w end) |> Enum.sum()

    if rows < changes do
      Logger.warning(
        "[ShadowProjector] #{state.project_id}: #{changes - rows} handler change(s) matched no row"
      )
    end

    state
  end

  # What this drain has to load, which is decided before anything is loaded.
  #
  # An unseeded projector reads every mark the same way: it has no prior state
  # for a delta to be relative to.
  defp plan(%{seeded: false}, _marks), do: :everything

  # Three claims, three costs.
  #
  # `unknown?` — some writer could not say what it moved, so the entity set is
  # not a complete account and the only safe reading is everything. That is the
  # whole-project pass this exists to replace, and it is what an un-narrowed
  # writer costs.
  #
  # `project?` — a writer said the project requirements moved. That adds one
  # entity to the set; it does not change the shape of the plan, because
  # `Preloader.load_project/2` is a narrow load like the other two.
  #
  # Anything else narrow. `Preloader.load/1` is reached only when a writer
  # could not say what it moved.
  defp plan(%{seeded: true}, marks) do
    {named, flags} = Invalidations.entities(marks)

    cond do
      flags[:unknown?] -> :everything
      flags[:project?] -> {:narrow, MapSet.put(named, {"project", nil})}
      true -> {:narrow, named}
    end
  end

  defp run(:everything, state, config) do
    {:ok, ctx} = Preloader.load(state.scope)

    # Computed once and written once. This used to compute every entity on its
    # own — `write_each/4`, one `compute_entity/4` and one `Shadow.write/3`
    # transaction per entity — and then call `reproject_topology/3`, which
    # computed every node a second time to get the edges. Measured on dev: the
    # seed after every restart was **17.9-19.9s, 26,395 queries, 14,945 rows**
    # across nine vantages, with `observations: 0`. Nothing had happened; the
    # process had merely started.
    #
    # `compute_topology/3` is one `compute_all_from_ctx/3` and one
    # `compute_edges/3`, which is exactly what the pass does on a cold vantage.
    {nodes, edges} = RequirementGraph.compute_topology(state.scope, ctx, config)

    covered = ctx |> all_entities() |> MapSet.put({"project", state.project_id})
    Shadow.write(state.scope, covered, nodes)
    {:ok, _count} = Shadow.write_edges(state.scope, edges)

    state = remember_topology(state, Freshness.topology(ctx, config))
    cache_analysis(state, ctx.analysis_fresh)
  end

  # The narrow path: one entity at a time, each loading only what it needs, and
  # no project-wide read at all.
  #
  # `analysis_fresh` is the one project-wide value a narrow computation still
  # needs — `bdd_specs_passing` reads it — and it is computed from the whole
  # checkout's files, so it is cached rather than recomputed per drain. Sound
  # because it can only move when files or an analyzer run move, and every
  # writer that does either records `:unknown`, which takes the `:everything`
  # branch above and refreshes it.
  #
  # Deduped by what each computation covered, for the reason `write_each/4`
  # gives: a component's unit is its family, so two marks naming siblings are
  # one piece of work.
  defp run({:narrow, entities}, state, config) do
    analysis_fresh =
      Map.get(state.analysis_fresh, vantage(state)) ||
        Preloader.analysis_freshness(state.scope)

    narrow_each(entities, state.scope, config, analysis_fresh)
    state = reproject_topology(state, config)
    cache_analysis(state, analysis_fresh)
  end

  @spec narrow_each(Enumerable.t(), Scope.t(), map(), map()) :: MapSet.t(Shadow.entity())
  defp narrow_each(entities, scope, config, analysis_fresh) do
    Enum.reduce(entities, MapSet.new(), fn entity, done ->
      if MapSet.member?(done, entity) do
        done
      else
        {:ok, ctx} = narrow_load(scope, entity, analysis_fresh)
        {covered, nodes} = RequirementGraph.compute_entity(scope, ctx, config, entity)
        Shadow.write(scope, covered, nodes)
        MapSet.union(done, covered)
      end
    end)
  end

  # Whether the shape moved, asked of the shape and nothing else — and if it
  # did, the edges rebuilt over the rows already written rather than by
  # recomputing every node.
  #
  # This called `Preloader.load/2` — the whole project — on every narrow drain
  # to compare one fingerprint, and on a move called `compute_topology/3`,
  # which computes every node to get the edges. The first is ~50 queries and
  # the largest phase of a pass, paid to learn that nothing had changed; the
  # second is the cost `template_edges/3` took out of the pass last night.
  # `topology_context/1` is four queries and holds exactly what
  # `Freshness.topology/2` and `Projection.rehydrate/2` read.
  defp reproject_topology(state, config) do
    shape = Preloader.topology_context(state.scope)
    last = Map.get(state.last_topology, vantage(state))

    case Freshness.topology(shape, config) do
      ^last ->
        state

      topology ->
        {nodes, _edges} = Projection.load(state.scope, shape, source: event_tables())
        edges = RequirementGraph.edges_over(state.scope, nodes, shape, config)
        {:ok, _count} = Shadow.write_edges(state.scope, edges)
        remember_topology(state, topology)
    end
  end

  defp event_tables, do: {Shadow.event_target(), {Shadow.event_edges(), Edge}}

  # Which checkout this drain is currently settling. `Projection.vantage/1`
  # rather than the raw field, so the unscoped reader keys the same way it
  # reads.
  defp vantage(state), do: Projection.vantage(state.scope)

  defp remember_topology(state, topology),
    do: %{state | last_topology: Map.put(state.last_topology, vantage(state), topology)}

  defp cache_analysis(state, freshness),
    do: %{state | analysis_fresh: Map.put(state.analysis_fresh, vantage(state), freshness)}

  defp narrow_load(scope, {"story", story_id}, analysis_fresh),
    do: Preloader.load_story(scope, story_id, analysis_fresh)

  defp narrow_load(scope, {"component", component_id}, analysis_fresh),
    do: Preloader.load_component_family(scope, component_id, analysis_fresh)

  defp narrow_load(scope, {"project", _}, analysis_fresh),
    do: Preloader.load_project(scope, analysis_fresh)

  defp all_entities(ctx) do
    MapSet.union(
      MapSet.new(ctx.components, &{"component", &1.id}),
      MapSet.new(ctx.stories, &{"story", &1.id})
    )
  end

  # Each entity in turn, skipping what an earlier one in this drain already
  # answered for.
  #
  @doc false
  def entity_of(%Invalidation{} = mark), do: Invalidation.entity(mark)
end
