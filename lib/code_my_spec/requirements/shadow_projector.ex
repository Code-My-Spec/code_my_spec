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

  alias CodeMySpec.Configurations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Freshness
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Invalidation
  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Requirements.Preloader
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
  Handle everything pending now, before the caller compares.

  The diff reads both projections, so it has to be asked at a moment when the
  event path has been given its chance — otherwise every mark still in flight
  reports as a difference and the number says more about timing than about
  coverage.
  """
  @spec settle(Ecto.UUID.t() | nil) :: :ok
  def settle(project_id) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :shadow}) do
      [{pid, _}] -> GenServer.call(pid, :drain, 30_000)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def settle(_no_project), do: :ok

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
       # The four analyzer-freshness booleans, kept between drains. Project-wide
       # and computed from the whole checkout's files, so recomputing it per
       # narrow drain would reintroduce the read the narrow path exists to
       # avoid. Only a writer that touched files or an analyzer run can move it,
       # and every one of those records `:unknown`.
       analysis_fresh: nil,
       # The topology this projector last wrote edges for. Edges are a global
       # computation, so the cheap question is whether they can have moved at
       # all — `Freshness.topology/2` is the same hash the pass records, over
       # component ids, types, parents, dependencies and the story population.
       last_topology: nil,
       last_drain: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, :ok, drain(state)}

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

  defp apply_marks(state, marks) do
    config = Configurations.get_or_create(state.scope)

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
          {handled, unhandled} = apply_handlers(state, marks)
          state = if unhandled == [], do: state, else: run(plan(state, unhandled), state, config)
          log_handled(state, handled)

          {state, %{handled: length(handled), recomputed: length(unhandled)}}
        end
      )

    # Only once the writes are done. A mark consumed before the work it asks
    # for is a mark that a crash turns into a permanently stale entity, which
    # is the failure the durable set exists to rule out.
    Invalidations.consume(marks)

    %{state | seeded: true, last_drain: DateTime.utc_now(), last_error: nil}
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

    ctx
    |> all_entities()
    |> MapSet.put({"project", nil})
    |> Enum.to_list()
    |> write_each(state.scope, ctx, config)

    state = reproject_topology(state, ctx, config)

    # The whole context was just read, so the cached freshness is current by
    # construction.
    %{state | analysis_fresh: ctx.analysis_fresh}
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
    analysis_fresh = state.analysis_fresh || Preloader.analysis_freshness(state.scope)
    narrow_each(entities, state.scope, config, analysis_fresh)
    state = reproject_topology(state, nil, config)
    %{state | analysis_fresh: analysis_fresh}
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

  # Topology, whenever this drain wrote nodes — and only then.
  #
  # Edges are a function of the node set: a sweep settles verdicts with
  # `UPDATE`s and cannot add or remove a node, so a drain that only swept cannot
  # have moved topology. Sweeps never reach `run/3` at all — `apply_marks/2`
  # calls it only for the marks no handler answered — so putting this here is
  # what confines a full topology computation to the fallback path.
  #
  # And it has to be the whole topology. `Topology.transitive_reduction/1` is
  # global: an edge here disappears because of a path through a node somewhere
  # else, so there is no subset of edges one entity's change is confined to.
  # `RequirementGraph.compute_topology/3` carries the long version.
  #
  # The `:everything` branch already holds a context; the narrow one has to read
  # one, which is the honest price of a global question. It is paid on entity
  # arrival and departure — a component created, retyped or deleted, a story
  # released or parked — and on nothing else.
  defp reproject_topology(state, ctx, config) do
    ctx = ctx || elem(Preloader.load(state.scope), 1)

    # Writing edges costs a whole-topology computation and a full replace —
    # measured at 8s and 57,000 rows on this project — so the first thing to ask
    # is whether topology can have moved at all. This hash is over component
    # ids, types, parents and dependencies plus the story population: exactly
    # the inputs edges are built from, and nothing a verdict touches.
    #
    # A fallback drain is usually one entity being recomputed for a reason that
    # has nothing to do with shape, so the common answer is no.
    last = state.last_topology

    case Freshness.topology(ctx, config) do
      ^last ->
        state

      topology ->
        {_nodes, edges} = RequirementGraph.compute_topology(state.scope, ctx, config)
        {:ok, _count} = Shadow.write_edges(state.scope, edges)
        %{state | last_topology: topology}
    end
  end

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
  # A component's unit is its family, so asking about a nested component answers
  # for its parent and siblings too. Without this, seeding recomputes each
  # family once per member — 549 of this project's 1138 components are nested —
  # and spends most of its time rewriting rows it just wrote.
  #
  # Not batching: nothing is deferred and no window is waited on. This declines
  # to redo work whose answer is already on disk.
  @spec write_each([Shadow.entity()], Scope.t(), map(), map()) :: MapSet.t(Shadow.entity())
  defp write_each(entities, scope, ctx, config) do
    Enum.reduce(entities, MapSet.new(), fn entity, done ->
      if MapSet.member?(done, entity),
        do: done,
        else: MapSet.union(done, compute_and_write(scope, ctx, config, entity))
    end)
  end

  # Answers with everything it covered, so the drain can skip those.
  defp compute_and_write(scope, ctx, config, {"project", _} = requested) do
    entity = {"project", scope.active_project_id}
    {covered, nodes} = RequirementGraph.compute_entity(scope, ctx, config, entity)
    Shadow.write(scope, covered, nodes)
    MapSet.put(covered, requested)
  end

  defp compute_and_write(scope, ctx, config, entity) do
    if present?(ctx, entity) do
      {covered, nodes} = RequirementGraph.compute_entity(scope, ctx, config, entity)
      Shadow.write(scope, covered, nodes)
      covered
    else
      Shadow.write(scope, [entity], [])
      MapSet.new([entity])
    end
  end

  defp present?(ctx, {"component", id}), do: Enum.any?(ctx.components, &(&1.id == id))
  defp present?(ctx, {"story", id}), do: Enum.any?(ctx.stories, &(&1.id == id))
  defp present?(_ctx, _entity), do: false

  @doc false
  def entity_of(%Invalidation{} = mark), do: Invalidation.entity(mark)
end
