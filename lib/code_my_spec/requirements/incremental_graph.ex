defmodule CodeMySpec.Requirements.IncrementalGraph do
  @moduledoc """
  One process per project, keeping the requirement graph current from
  invalidation marks: the incremental graph, and the only thing that writes it.

  It writes `requirements` and `requirement_edges` (through `GraphStore`) and
  announces what moved. `GraphWatcher` is the front callers use to start and
  settle it.

  A mark that arrives is drained; there is no timer. Each drain applies the
  events it has handlers for, and plans the rest before loading anything:
  `:everything` when a writer could not say what it moved or the projector has
  not seeded, otherwise one narrow load per named entity (`Preloader.load/1` is
  never called). A drain that raises leaves its marks queued — they are
  consumed only after the writes — so the next drain retries them.

  See knowledge/requirements_graph, "Marks and drains" and "Seeding".
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Configurations
  alias CodeMySpec.Faults
  alias CodeMySpec.Repo
  alias CodeMySpec.Repo.SandboxAllowance
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Edges
  alias CodeMySpec.Requirements.Freshness
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Invalidation
  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  # -- Client --

  def start_link({project_id, scope}), do: start_link({project_id, scope, nil})

  # `owners` are the processes whose sandbox connection this one uses under
  # test (`SandboxAllowance.owners/0`). Taken in `init/1`, before the first
  # drain this process sends itself; granted afterwards, it raced that drain.
  def start_link({project_id, scope, owners}) do
    GenServer.start_link(__MODULE__, {project_id, scope, owners}, name: via(project_id))
  end

  def via(project_id),
    do: {:via, Registry, {CodeMySpec.Requirements.Registry, {project_id, :graph}}}

  @doc """
  Project this project's marks, if nothing is projecting them yet.
  """
  @spec ensure_projecting(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_projecting(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_projecting(%Scope{active_project_id: project_id} = scope) do
    case DynamicSupervisor.start_child(
           CodeMySpec.Requirements.WatcherSupervisor,
           {__MODULE__, {project_id, scope, SandboxAllowance.owners()}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Whether a projector is running for this project, and therefore whether
  anything is going to consume its marks.
  """
  @spec running?(Ecto.UUID.t() | nil) :: boolean()
  def running?(project_id) when is_binary(project_id) do
    Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :graph}) != []
  end

  def running?(_no_project), do: false

  @doc """
  Handle everything pending now, before the caller compares.

  A reader settles before it reads, so a mark still in flight is never served
  as the graph. `:ok` when nothing projects the project. A projector that dies
  under the call is not `:ok`: see `unsettled/3`.
  """
  @spec settle(Ecto.UUID.t() | nil, Enumerable.t()) :: :ok
  def settle(project_id, requested \\ [])

  def settle(project_id, requested) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :graph}) do
      # Re-granted from each reader: the projector outlives whoever started it.
      [{pid, _}] ->
        SandboxAllowance.grant(pid)
        drained(pid, requested, settle_attempts())

      [] ->
        :ok
    end
  catch
    :exit, reason -> unsettled(project_id, :settle, reason)
  end

  def settle(_no_project, _requested), do: :ok

  # A call that times out is not a drain that did not happen: the message is in
  # the projector's mailbox and is still processed. Giving up at the first
  # timeout served the rows as they were while the projector was seeding every
  # vantage after a reload (about a minute, longer under load), and a reader that
  # asked again got the same answer for the same reason (issue e3c09c4d: eight
  # warnings in a minute right after landings, and 1055 reading a stale
  # story_promoted). So a timeout is waited on again, a bounded number of times;
  # only a projector that stays silent through all of them is unsettled. The
  # attempts and the per-call timeout are config, for the test that makes a
  # drain slower than the call.
  defp drained(pid, requested, attempts_left) do
    GenServer.call(pid, {:drain, requested}, settle_timeout_ms())
  catch
    :exit, {:timeout, {GenServer, :call, _}} when attempts_left > 1 ->
      Logger.info(
        "[IncrementalGraph] drain still running after #{settle_timeout_ms()}ms; " <>
          "waiting again (#{attempts_left - 1} left)"
      )

      drained(pid, requested, attempts_left - 1)
  end

  defp settle_attempts, do: Application.get_env(:code_my_spec, :graph_settle_attempts, 4)

  defp settle_timeout_ms, do: Application.get_env(:code_my_spec, :graph_settle_timeout_ms, 30_000)

  @doc """
  Rebuild one vantage from the domain: forget that this process established it,
  then drain, which seeds it whole. For "recompute now" — a story with no rows
  is not something any observation will create.
  """
  @spec reproject(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: :ok
  def reproject(project_id, vantage) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :graph}) do
      [{pid, _}] ->
        SandboxAllowance.grant(pid)
        GenServer.call(pid, {:reproject, vantage}, 30_000)

      [] ->
        :ok
    end
  catch
    :exit, reason -> unsettled(project_id, :reproject, reason)
  end

  # The projector was there and the call did not come back. Not `:ok`: that
  # served the rows as a settled graph, so a killed projector read as an empty
  # one. Under the sandbox a kill, crash or timeout raises; a normal stop or a
  # projector already gone is a test that ended, read by a task it left behind,
  # and is only logged. Outside the sandbox: logged, rows served as they are.
  # See knowledge/requirements_graph, "Tests and the sandbox".
  defp unsettled(project_id, call, reason) do
    message =
      "[IncrementalGraph] #{call} for #{project_id} did not complete: the projector " <>
        "exited with #{inspect(reason, limit: 8, printable_limit: 200)}"

    if SandboxAllowance.sandboxed?() and not ended?(reason), do: raise(message)
    Logger.warning(message)
    :ok
  end

  defp ended?({reason, {GenServer, :call, _}}), do: reason in [:normal, :noproc]
  defp ended?(_reason), do: false

  @doc """
  What this projector last did, in the shape `GraphWatcher.status/1` answers,
  so a reader served from its rows is told about the writer it is served from.
  """
  @spec status(Ecto.UUID.t() | nil) :: map() | nil
  def status(project_id) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, {project_id, :graph}) do
      [{pid, _}] -> GenServer.call(pid, :status, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  def status(_no_project), do: nil

  # -- Server --

  @impl true
  def init({project_id, scope, owners}) do
    SandboxAllowance.take(owners)
    # So a supervisor's `:shutdown` waits for the drain in flight: dying
    # mid-transaction takes a shared sandbox connection down with it.
    Process.flag(:trap_exit, true)

    GraphInputs.subscribe(project_id)

    # Establish every vantage on arrival: a vantage with rows is trusted (rows
    # and marks are durable), one without is seeded whole. Sent rather than done
    # here because a seed can be a whole graph and `init/1` blocks the
    # supervisor. See knowledge/requirements_graph, "Seeding".
    send(self(), :seed)

    {:ok,
     %{
       project_id: project_id,
       scope: scope,
       seeded: false,
       # The starter's vantage is established in the first drain, not when
       # something first reads it.
       requested_vantages: MapSet.new([scope.active_working_copy_id]),
       # Vantages this process has seen rows for (its own writes or rows found).
       established_vantages: MapSet.new(),
       # Per vantage: the `Freshness.topology/2` hash the edges were last drawn
       # for, so a drain can ask whether edges can have moved at all.
       last_topology: %{},
       # Generated edges keyed by shape and discovered-file membership.
       # See `edge_plan/3`.
       edge_plan: nil,
       last_drain: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call({:drain, requested}, _from, state) do
    {:reply, :ok, state |> remember(requested) |> drain()}
  end

  def handle_call({:reproject, vantage}, _from, state) do
    state = %{
      state
      | established_vantages: MapSet.delete(state.established_vantages, vantage),
        requested_vantages: MapSet.put(state.requested_vantages, vantage)
    }

    state = state |> Map.put(:drain_kind, :reseed) |> drain() |> Map.delete(:drain_kind)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       # A mark is drained when it arrives, so nothing waits between drains.
       pending: false,
       last_recompute: state.last_drain,
       last_error: state.last_error,
       seeded: state.seeded
     }, state}
  end

  @impl true
  def handle_info(:seed, state), do: {:noreply, drain(state)}

  def handle_info({:graph_inputs_changed, _project_id, _obs}, state),
    do: {:noreply, drain(state)}

  def handle_info({:graph_inputs_changed, _project_id}, state), do: {:noreply, drain(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # Nothing pending, seeded, and every requested vantage established is the
  # common case and costs one query. Otherwise it computes: an unseeded
  # projector must establish what is true before deltas mean anything, and a
  # vantage a reader asked about that no mark names would never be written.
  defp drain(state) do
    # The dev fault `graph_recompute_fails` (`POST /dev/faults`).
    refuse_if_faulted(state.project_id)

    case {state.seeded, Invalidations.pending(state.project_id), unestablished(state)} do
      # Requests already served are forgotten, or every later drain settles
      # them again.
      {true, [], []} -> %{state | requested_vantages: MapSet.new()}
      {_seeded, marks, _asked} -> apply_marks(state, marks)
    end
  rescue
    error in DBConnection.OwnershipError ->
      owner_gone(state, Exception.message(error))

    error ->
      # 09fd73a4: this swallows any recompute failure other than a sandbox
      # owner going away, leaving the cached graph exactly as stale as before
      # the attempt -- a satisfied requirement (ready_for_qa, qa_complete)
      # can then be re-offered forever if the recompute that would clear it
      # keeps hitting the same bug. Logging the stacktrace alongside the
      # message (nothing else changes) is what finds that bug's call site;
      # without it, only the exception's name and message survive.
      Logger.warning(
        "[IncrementalGraph] #{state.project_id} left #{inspect(error.__struct__)} pending: " <>
          Exception.message(error) <>
          "\n" <> Exception.format(:error, error, __STACKTRACE__)
      )

      %{state | last_error: %{at: DateTime.utc_now(), message: Exception.message(error)}}
  catch
    :exit, reason ->
      if SandboxAllowance.sandboxed?() and sandbox_gone?(reason),
        do: owner_gone(state, "owner exited"),
        else: exit(reason)
  end

  # Only under the sandbox: the test that owned this projector's connection has
  # ended. Stopped normally: a crash is restarted into the same dead sandbox,
  # and enough of those trip the supervisor's restart intensity.
  defp owner_gone(state, why) do
    Logger.warning(
      "[IncrementalGraph] stopping: the sandbox owner for #{state.project_id} is gone (#{why})"
    )

    exit(:normal)
  end

  # Every shape a checkout exits with once the owning test has finished: the
  # owner exited (string or ConnectionError), the holder is gone, or another
  # client of the connection exited mid-query. Each unmatched shape is a crash
  # toward `WatcherSupervisor`'s restart intensity. Asked only under the
  # sandbox; outside it a checkout that exits is a real fault.
  defp sandbox_gone?({reason, {DBConnection.Holder, :checkout, _}}), do: sandbox_gone?(reason)
  defp sandbox_gone?({:shutdown, "owner " <> _}), do: true
  defp sandbox_gone?({:shutdown, %DBConnection.ConnectionError{message: "owner " <> _}}), do: true

  defp sandbox_gone?({:shutdown, %DBConnection.ConnectionError{message: "client " <> _}}),
    do: true

  defp sandbox_gone?(:noproc), do: true
  defp sandbox_gone?(_reason), do: false

  # Settles each vantage the marks name — a mark records the checkout it was
  # written from; `nil` (not about a checkout) fans out to every vantage.
  # See knowledge/requirements_graph, "Vantages".
  defp apply_marks(state, marks) do
    config = Configurations.get_or_create(state.scope)
    base_scope = state.scope

    # Events first; what has no handler falls through to `plan/2`. The cost
    # line reports `handled` against `recomputed`, since a drain that fell back
    # costs a recompute. See knowledge/requirements_graph, "Verdicts and handlers".
    state =
      DrainCost.measure(
        %{
          kind: Map.get(state, :drain_kind, :event),
          project_id: state.project_id,
          observations: length(marks)
        },
        fn ->
          vantages = vantages(state, marks)

          # Counted per vantage: a hit at one checkout must not cover a miss at
          # another in `log_handled/2`.
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

    # Only once the writes are done: a mark consumed first is one a crash turns
    # into a permanently stale entity.
    Invalidations.consume(marks)
    account_for(marks, state.project_id)
    announce(state, marks)

    # Served, so forgotten; marks keep those vantages current from here.
    %{
      state
      | seeded: true,
        requested_vantages: MapSet.new(),
        last_drain: DateTime.utc_now(),
        last_error: nil
    }
  end

  defp account_for([], _project_id), do: :ok

  defp account_for(marks, project_id) do
    ids = marks |> Enum.map(& &1.observation_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Logger.info("[IncrementalGraph] accounted for #{length(ids)} observation(s)",
      obs: Enum.join(ids, ","),
      cms_project: project_id
    )
  end

  # Readers refresh on `{:graph_updated, project_id}`; agents are woken off the
  # `graph_changed` telemetry. Only when something was consumed.
  defp announce(_state, []), do: :ok

  defp announce(state, _marks) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      GraphInputs.topic(state.project_id),
      {:graph_updated, state.project_id}
    )

    # Answered by `Agents.GraphWake`, which starts the wake off this process.
    :telemetry.execute(
      [:code_my_spec, :requirements, :graph_changed],
      %{},
      %{scope: state.scope}
    )

    :ok
  end

  # The vantages to settle. Unseeded: every stored and requested vantage,
  # since the seed asks "what is true", not "what did these marks move".
  # Seeded: the checkouts the marks name plus requested ones; a `nil` mark fans
  # out to all. The `nil` *vantage* (no-checkout readers) reads the default
  # checkout's files, so it is kept only when that checkout's marks moved it.
  # See knowledge/requirements_graph, "Vantages".
  defp vantages(%{seeded: false} = state, _marks) do
    stored = Projection.vantages(state.scope)
    Projection.live_vantages(state.scope, stored ++ MapSet.to_list(state.requested_vantages))
  end

  defp vantages(state, marks) do
    requested = MapSet.to_list(state.requested_vantages)
    named = marks |> Enum.map(& &1.working_copy_id) |> Enum.uniq()

    if Enum.any?(named, &is_nil/1) do
      Projection.live_vantages(state.scope, Projection.vantages(state.scope))
    else
      # `nil` reads the default checkout's files, or every checkout's when the
      # project has none.
      keep_nil? =
        case Preloader.files_vantage(state.scope) do
          nil -> true
          default -> default in named
        end

      state.scope
      |> Projection.live_vantages(Enum.concat(named, requested))
      |> Enum.filter(&(keep_nil? or not is_nil(&1) or &1 in requested))
    end
  end

  # The vantages readers asked about, considered in the next drain even when no
  # mark names them. Not a recompute-on-read: an established vantage with
  # nothing pending costs nothing.
  defp remember(state, requested) do
    %{state | requested_vantages: Enum.into(requested, state.requested_vantages)}
  end

  # Each event offered to its handler; anything without one handed back.
  # `{:ok, []}` (moved nothing the graph reads) is not `:no_handler` (unknown,
  # must re-derive).
  defp apply_handlers(state, marks) do
    {handled, rest} = split_handled(state, marks)

    # An invalidation beside a handled event is that event's fallback: dropped by
    # observation id, or the handled event would recompute its entities too.
    answered =
      handled
      |> Enum.reject(fn {mark, _c, _w} -> Handlers.partial_event?(mark) end)
      |> MapSet.new(fn {mark, _c, _w} -> mark.observation_id end)

    {handled,
     Enum.reject(rest, fn mark ->
       mark.observation_id != nil and MapSet.member?(answered, mark.observation_id)
     end)}
  end

  # One settle per distinct kind, not per mark: a handler is a function of
  # current state (it ignores the payload), so running it twice in a drain pays
  # twice for the same answer, and marks arrive in bulk. Every mark of a handled
  # kind is still returned — `apply_handlers/2` drops fallbacks by observation
  # id — but only the first carries the changes, so work is counted once.
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

  # One transaction for the event's verdicts and sweeps, so a reader never sees
  # one requirement settled against another's previous answer. Sweeps skip
  # unchanged rows, so the steady state locks nothing.
  defp settle(scope, changes, sweeps) do
    {:ok, written} =
      Repo.transaction(fn ->
        written = Enum.map(changes, &write_change(scope, &1))
        Enum.each(sweeps, &GraphStore.sweep(scope, &1))
        written
      end)

    written
  end

  defp handler_result(_scope, %Invalidation{kind: kind}) when kind in [nil, "invalidate"],
    do: :no_handler

  defp handler_result(scope, %Invalidation{kind: kind, payload: payload}),
    do: Handlers.apply_event(scope, kind, payload || %{})

  defp write_change(scope, change) do
    {:ok, count} = GraphStore.put_verdict(scope, change)
    count
  end

  # Applies the handled events at this vantage, then whatever is left: a seed
  # for an unestablished vantage (whatever the marks say — the seed has none),
  # a baseline or edge redraw when handlers covered everything, else a plan.
  defp settle_vantage(vantage, {state, handled, recomputed, kinds}, marks, base_scope, config) do
    state = %{state | scope: %{base_scope | active_working_copy_id: vantage}}
    {applied, unhandled} = apply_handlers(state, marks)

    shape_moved? =
      Enum.any?(applied, fn {mark, _c, _w} -> mark.kind in Handlers.shape_kinds() end)

    # Rows are trusted; edges are redrawn once per vantage per process, by
    # `baseline/2` for verdict-only drains and `reproject_topology/3` when the
    # shape could have moved.
    state =
      cond do
        # A vantage with no rows has nothing to be partial against.
        not established?(state, vantage, config) -> run(:everything, state, config)
        unhandled == [] and not shape_moved? -> baseline(state, config)
        unhandled == [] -> reproject_topology(state, config, false)
        true -> run_plan(state, unhandled, config)
      end

    state = %{state | established_vantages: MapSet.put(state.established_vantages, vantage)}
    log_handled(state, applied)

    {state, handled + length(applied), recomputed + length(unhandled),
     tally(kinds, applied, unhandled)}
  end

  defp refuse_if_faulted(project_id) do
    if Faults.active?(project_id, :graph_recompute_fails) do
      raise RuntimeError, "graph recompute failed (fault injected for this project)"
    end
  end

  # Whether this vantage has rows to be partial against: seen by this process,
  # or found in the table and covering every current definition (a release that
  # adds a requirement moves no observation — `GraphStore.definitions_covered?/2`).
  defp established?(state, vantage, config) do
    MapSet.member?(state.established_vantages, vantage) or
      (GraphStore.projected?(state.scope) and
         GraphStore.definitions_covered?(
           state.scope,
           RequirementGraph.defined_names(Preloader.topology_context(state.scope), config)
         ))
  end

  # The checkouts readers asked about that nothing here has written or seen.
  defp unestablished(state),
    do:
      state.requested_vantages
      |> MapSet.difference(state.established_vantages)
      |> MapSet.to_list()

  # Which kinds this drain handled and which it fell back on, by mark count,
  # so the cost line attributes queries to kinds.
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
        "[IncrementalGraph] #{state.project_id}: #{changes - rows} handler change(s) matched no row"
      )
    end

    state
  end

  defp run_plan(state, unhandled, config), do: run(plan(state, unhandled), state, config)

  # A vantage met with rows already there is redrawn once per process, then
  # left alone: its rows are trusted, but its edges were drawn under whatever
  # templates the previous process had, and a release that moves a
  # prerequisite moves edges and no row. See knowledge/requirements_graph, "Edges".
  defp baseline(state, config) do
    if Map.has_key?(state.last_topology, vantage(state)),
      do: state,
      else: reproject_topology(state, config, false)
  end

  # What this drain has to load, decided before anything is loaded:
  # everything when a writer could not say what it moved (`unknown?`), else the
  # named entities, plus the project when a writer said the project moved.
  defp plan(_state, marks) do
    {named, flags} = Invalidations.entities(marks)

    cond do
      flags[:unknown?] -> :everything
      flags[:project?] -> {:narrow, MapSet.put(named, {"project", nil})}
      true -> {:narrow, named}
    end
  end

  defp run(:everything, state, config) do
    {:ok, ctx} = Preloader.load(state.scope)

    # Every node computed once and written in one write; computing entity by
    # entity cost a seed tens of seconds. See knowledge/requirements_graph, "Seeding".
    {nodes_us, {nodes, enriched}} =
      :timer.tc(fn -> RequirementGraph.compute_nodes(state.scope, ctx, config) end)

    topology = Freshness.topology(ctx, config)
    covered = ctx |> all_entities() |> MapSet.put({"project", state.project_id})

    {write_us, {:ok, _moved}} = :timer.tc(fn -> GraphStore.write(state.scope, covered, nodes) end)

    # Edges drawn over the rows just written, per vantage: every checkout sees
    # its own stories, so no two vantages share a node set.
    {state, drawn} = redraw(state, enriched, config)

    Logger.info(
      "[IncrementalGraph] seeded #{inspect(vantage(state))} — #{length(nodes)} nodes in " <>
        "#{div(nodes_us, 1000)}ms, written in #{div(write_us, 1000)}ms; " <>
        "#{drawn.edges} edges in #{drawn.draw_ms}ms, #{drawn.moved} written in #{drawn.write_ms}ms"
    )

    remember_topology(state, topology)
  end

  # The narrow path: one entity at a time, each loading only what it needs, and
  # no project-wide read. Deduped by what each computation covered: a
  # component's unit is its family, so two marks naming siblings are one.
  defp run({:narrow, entities}, state, config) do
    {_done, node_set_moved?} = narrow_each(entities, state.scope, config)
    reproject_topology(state, config, node_set_moved?)
  end

  # Answers whether any write added or reaped a row, beside what it covered.
  @spec narrow_each(Enumerable.t(), Scope.t(), map()) ::
          {MapSet.t(GraphStore.entity()), boolean()}
  defp narrow_each(entities, scope, config) do
    Enum.reduce(entities, {MapSet.new(), false}, fn entity, {done, moved?} ->
      if MapSet.member?(done, entity) do
        {done, moved?}
      else
        {:ok, ctx} = narrow_load(scope, entity)
        {covered, nodes} = RequirementGraph.compute_entity(scope, ctx, config, entity)
        {:ok, %{inserted: inserted, reaped: reaped}} = GraphStore.write(scope, covered, nodes)
        {MapSet.union(done, covered), moved? or inserted > 0 or reaped > 0}
      end
    end)
  end

  # Redraws edges over the stored rows when the shape (`Freshness.topology/2`)
  # moved or a write inserted or reaped a row — the two move in different
  # drains, so both are asked. No baseline (`last` is nil) means redraw.
  # See knowledge/requirements_graph, "Edges".
  defp reproject_topology(state, config, node_set_moved?) do
    shape = Preloader.topology_context(state.scope)
    last = Map.get(state.last_topology, vantage(state))
    topology = Freshness.topology(shape, config)

    if topology == last and not node_set_moved? do
      state
    else
      # A membership change (including a story moving into this checkout) can
      # be handled by verdict sweeps, which cannot create its missing rows.
      # Establish those entities before drawing edges over the stored nodes.
      expected = RequirementGraph.defined_entities(shape, config)
      incomplete = GraphStore.incomplete_entities(state.scope, expected)
      narrow_each(incomplete, state.scope, config)
      {state, drawn} = redraw(state, shape, config)

      Logger.info(
        "[IncrementalGraph] redrew #{inspect(vantage(state))} — #{drawn.edges} edges in " <>
          "#{drawn.draw_ms}ms, #{drawn.moved} written in #{drawn.write_ms}ms"
      )

      remember_topology(state, topology)
    end
  end

  # The edge set at this vantage, drawn over the rows it holds (one entity at a
  # time against the component side) and written as a difference. Announced as
  # an edge rebuild, so a drain of verdicts can be shown to have drawn nothing.
  defp redraw(state, shape, config) do
    {state, plan} = edge_plan(state, shape, config)
    ids = GraphStore.node_ids(state.scope)
    story_ids = Enum.map(shape.stories, & &1.id)

    {draw_us, edges} = :timer.tc(fn -> Edges.over(plan, story_ids, GraphStore.present?(ids)) end)

    {write_us, {:ok, moved}} =
      :timer.tc(fn -> GraphStore.write_edges(state.scope, edges, ids) end)

    :telemetry.execute(
      DrainCost.edges_rebuilt(),
      %{count: 1, nodes: map_size(ids)},
      %{project_id: state.project_id}
    )

    {state,
     %{
       edges: length(edges),
       moved: moved,
       draw_ms: div(draw_us, 1000),
       write_ms: div(write_us, 1000)
     }}
  end

  # Reuse a generated plan only when both the project shape and this
  # checkout's discovered-component file membership match. Story dependency
  # closure excludes discoveries with no files here, so a project-wide plan
  # alone can introduce dependencies belonging to a different checkout.
  defp edge_plan(state, shape, config) do
    file_component_ids =
      Map.get_lazy(shape, :file_component_ids, fn ->
        shape.files_by_component
        |> Enum.reject(fn {_id, files} -> files == [] end)
        |> MapSet.new(fn {id, _files} -> id end)
      end)

    wide =
      state.scope
      |> Map.put(:active_working_copy_id, nil)
      |> Preloader.topology_context()
      |> Map.put(:file_component_ids, file_component_ids)

    key = Freshness.topology(wide, config)

    case state.edge_plan do
      {^key, plan} ->
        {state, plan}

      _stale_or_none ->
        {plan_us, plan} = :timer.tc(fn -> Edges.plan(state.scope, wide, config) end)

        Logger.info(
          "[IncrementalGraph] planned edges for #{map_size(plan.stories)} stories over " <>
            "#{length(plan.component_side)} component-side edges in #{div(plan_us, 1000)}ms"
        )

        {%{state | edge_plan: {key, plan}}, plan}
    end
  end

  # Which checkout this drain is currently settling. `Projection.vantage/1`
  # rather than the raw field, so the unscoped reader keys the same way it
  # reads.
  defp vantage(state), do: Projection.vantage(state.scope)

  defp remember_topology(state, topology),
    do: %{state | last_topology: Map.put(state.last_topology, vantage(state), topology)}

  defp narrow_load(scope, {"story", story_id}), do: Preloader.load_story(scope, story_id)

  defp narrow_load(scope, {"component", component_id}),
    do: Preloader.load_component_family(scope, component_id)

  defp narrow_load(scope, {"project", _}), do: Preloader.load_project(scope)

  defp all_entities(ctx) do
    MapSet.union(
      MapSet.new(ctx.components, &{"component", &1.id}),
      MapSet.new(ctx.stories, &{"story", &1.id})
    )
  end

  @doc false
  def entity_of(%Invalidation{} = mark), do: Invalidation.entity(mark)
end
