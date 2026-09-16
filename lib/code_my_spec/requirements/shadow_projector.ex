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

  ## The context read is scaffolding, and is the next thing to go

  Each drain loads the whole project context once and computes each entity
  against it. That shared read is the one thing here still shaped like the
  batched system, and it is load-bearing for nothing: it is here because
  `Preloader.load/1` only knows how to load a project, and a per-entity loader
  is a change worth making with a working correctness oracle already in place
  rather than before one.

  Until then the shadow is honest about *what* it computes and not yet about
  *what it costs*, and only the first of those is what the diff measures.

  ## Failure is loud and nothing is dropped

  A drain that raises leaves its marks in place — `consume/1` runs only after
  the writes — so the next event retries them. A projector that cannot keep up
  or keeps failing shows as a growing `pending` count, which is the honest
  signal and the one an in-memory dirty set could never give.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Configurations
  alias CodeMySpec.Requirements.GraphInputs
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
    {:ok, ctx} = Preloader.load(state.scope)
    config = Configurations.get_or_create(state.scope)

    state
    |> entities_to_compute(marks, ctx)
    |> Enum.reduce(MapSet.new(), fn entity, done ->
      # Skipping what a previous computation in this drain already answered for.
      #
      # A component's unit is its family, so asking about a nested component
      # answers for its parent and siblings too. Without this, seeding a project
      # recomputes each family once per member — on this project, 549 of 1138
      # components are nested, and the seed spent most of its time recomputing
      # families it had already written.
      #
      # Not batching: nothing is deferred and no window is waited on. This only
      # declines to redo work whose answer is already on disk.
      if MapSet.member?(done, entity) do
        done
      else
        MapSet.union(done, compute_and_write(state.scope, ctx, config, entity))
      end
    end)

    # Only once the writes are done. A mark consumed before the work it asks
    # for is a mark that a crash turns into a permanently stale entity, which
    # is the failure the durable set exists to rule out.
    Invalidations.consume(marks)

    %{state | seeded: true, last_drain: DateTime.utc_now(), last_error: nil}
  end

  # A project-wide mark means the writer could not say what moved, so the only
  # safe reading is "any of it" — every entity, which is precisely the
  # whole-project pass this replaces. That is the cost of leaving a writer
  # un-narrowed, and it is paid here so the diff can price it.
  #
  # An unseeded projector reads every mark the same way, whatever it names: it
  # has no prior state for a delta to be relative to.
  defp entities_to_compute(%{seeded: false}, _marks, ctx),
    do: ctx |> all_entities() |> MapSet.put({"project", nil}) |> Enum.to_list()

  defp entities_to_compute(%{seeded: true}, marks, ctx) do
    {named, project_wide?} = Invalidations.entities(marks)

    named
    |> then(fn named -> if project_wide?, do: all_entities(ctx), else: named end)
    |> MapSet.put({"project", nil})
    |> Enum.to_list()
  end

  defp all_entities(ctx) do
    MapSet.union(
      MapSet.new(ctx.components, &{"component", &1.id}),
      MapSet.new(ctx.stories, &{"story", &1.id})
    )
  end

  # A mark can name an entity the project no longer has — the delete that made
  # it is exactly when a mark matters — so the write is skipped and the mark is
  # still consumed. `Shadow.write/3` with no nodes would delete the rows anyway;
  # this only avoids computing against a context that does not hold it.
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
