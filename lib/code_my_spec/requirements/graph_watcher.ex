defmodule CodeMySpec.Requirements.GraphWatcher do
  @moduledoc """
  One process per project, turning input changes into a recomputed graph.

  Subscribes to `GraphInputs`, debounces the flurry, asks the fingerprint
  whether anything really moved, recomputes when it did, and says so.

  ## The shape, and why it is this one

  Reads stay reads. Before this, the only thing that ever recomputed the graph
  was somebody reading it, so an idle agent never learned that work had appeared
  — measured at ninety minutes of a product agent waiting while four issues sat
  untriaged.

  The alternative was a proxy per writer: `TaskEvaluator` woke roles when a task
  completed, and an issue being filed was about to become the second. Ten
  fingerprint inputs and two proxies is a list that rots, and each gap looks
  exactly like the silence above. John: "writer side events are the way I think.
  At least the logic is centralized and reads are reads."

  ## Debounce

  A single sync writes hundreds of files and a three-amigos session writes a
  rule, its scenarios and its criteria in one breath. Recomputing per event
  would be a ~170ms graph per row. So an event schedules a pass and further
  events fold into it — one recompute for a burst, the debounce window after it
  stops.

  Coalescing, not throttling: the timer is not extended by later events, so a
  steady stream still recomputes every window rather than never.

  ## The fingerprint decides, not the event

  An event means "somebody wrote something", which is not the same as "the graph
  is different" — a story renamed, a file touched with the same content. The
  fingerprint already answers the real question over every input at once, so a
  pass that finds it unmoved does nothing and costs one preload.

  That is also why events carry no payload. What changed is not interesting;
  whether the answer changed is.

  ## What it emits, and the one thing it does itself

  `{:graph_updated, project_id}` on this project's topic, for anyone who wants
  to know — the requirements LiveViews are the obvious future subscriber.

  It also wakes the project's agents directly rather than through that event.
  Waking is not an optional consumer: it is the reason this exists, and routing
  it through a second process to subscribe to our own broadcast would put a
  mailbox between a graph that moved and the agent that has been waiting for it.
  `Agents.wake_project_roles/2` is already menu-gated, so a role with nothing to
  do is not charged a turn.
  """

  use GenServer, restart: :transient

  require Logger

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Faults
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Shadow
  alias CodeMySpec.Requirements.ShadowProjector
  alias CodeMySpec.Users.Scope
  alias Ecto.Adapters.SQL.Sandbox

  # Two seconds, and the number is picked from what the writers actually do.
  #
  # A file sync announces once at the end of a whole scan, not per file, so the
  # burst this has to swallow is not thousands of rows — it is a handful of
  # writers landing together: a sync finishing while an agent files two issues
  # and submits a QA result. Those arrive inside a second or so of each other.
  #
  # The cost of being too short is a duplicate recompute, and the fingerprint
  # makes the second one a preload rather than a graph. The cost of being too
  # long is an agent sitting idle for exactly that long with work waiting — the
  # thing this whole mechanism exists to end. So it is short, and the error is
  # on the cheap side.
  @default_debounce_ms 2_000

  # Configurable so tests can collapse it. `settle/1` already makes the pass
  # deterministic for a test that calls it, but a test asserting what happens
  # *without* settling — that a burst coalesces, that a steady stream still
  # gets a pass — otherwise waits two real seconds per assertion.
  #
  # Read at schedule time rather than captured at boot: a test that changes it
  # in `setup` would otherwise be ignored by a watcher already running, and
  # watchers outlive individual tests.
  defp debounce_ms do
    Application.get_env(:code_my_spec, :graph_debounce_ms, @default_debounce_ms)
  end

  # -- Client --

  def start_link({project_id, scope}) do
    GenServer.start_link(__MODULE__, {project_id, scope}, name: via(project_id))
  end

  def via(project_id), do: {:via, Registry, {CodeMySpec.Requirements.Registry, project_id}}

  @doc """
  Watch this project, if nothing is watching it yet.

  Idempotent and cheap to call from anywhere a scope is in hand — the second
  caller gets the running one. Started on demand rather than for every project
  at boot: a project nobody is working on needs no watcher, and enumerating them
  all would start hundreds of processes for the handful that are live.
  """
  @spec ensure_watching(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_watching(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_watching(%Scope{active_project_id: project_id} = scope) do
    # The event-based projection is maintained beside this one whenever the
    # experiment is on, so both are fed by the same traffic on the same
    # projects. Started here rather than anywhere else because this is what
    # decides a project is being worked on; `ensure_projecting/1` refuses when
    # the flag is off, so this costs a function call in the normal case.
    ShadowProjector.ensure_projecting(watcher_scope(scope))

    case DynamicSupervisor.start_child(
           CodeMySpec.Requirements.WatcherSupervisor,
           {__MODULE__, {project_id, watcher_scope(scope)}}
         ) do
      {:ok, pid} -> {:ok, allow_sandbox(pid)}
      {:error, {:already_started, pid}} -> {:ok, allow_sandbox(pid)}
      other -> other
    end
  end

  # The watcher outlives whatever called this and has no sandbox ownership of
  # its own, so under test its queries are at the mercy of whatever the
  # process-global sandbox mode happens to be at the moment it runs one —
  # someone else's connection if any non-async test has set `{:shared, _}`
  # since, or the real (non-transactional) pool if `:manual` mode has never
  # been granted to it at all. `allow/3` gives this specific pid this
  # specific caller's connection, explicitly, instead of leaving it to
  # whatever the ambient mode says: the caller is `self()` here because
  # every path into this function — the session-start hook, a continuous-mode
  # toggle — runs inline in the process that is asking, sandboxed or not.
  # No-op outside a sandboxed pool (dev, prod, drill/e2e), same guard this
  # codebase already uses for `real_pool?/0`.
  defp allow_sandbox(pid) do
    if Application.get_env(:code_my_spec, CodeMySpec.Repo, [])[:pool] == Sandbox do
      Sandbox.allow(Repo, self(), pid)
    end

    pid
  end

  # The scope outlives the request that started the watcher, so it keeps only
  # what a computation needs and none of the caller's session. A watcher holding
  # a `conn`-shaped scope would be answering for whoever happened to be first.
  defp watcher_scope(%Scope{} = scope) do
    %Scope{
      user: scope.user,
      user_id: scope.user_id,
      active_account: scope.active_account,
      active_account_id: scope.active_account_id,
      active_project: scope.active_project,
      active_project_id: scope.active_project_id,
      active_working_copy_id: scope.active_working_copy_id
    }
  end

  @doc """
  Do any pending recompute now, before the caller reads.

  A reader that arrives while the debounce timer is ticking would otherwise
  compute the graph itself, publish it, and leave the timer to fire into a
  fingerprint that now hits — correct, and two passes over the same change. Worse
  for an agent: the read it is about to do is the one that decides what it works
  on next, and doing it a beat before the recompute means deciding from the
  older answer.

  So a caller says "settle first". No watcher and nothing pending are both `:ok`
  — this is an ordering request, not a dependency, and a project nobody is
  watching has nothing to settle.

  `catch :exit` because a watcher can stop between the lookup and the call, and
  a reader must not fail for wanting to be current.
  """
  @spec settle(Scope.t() | Ecto.UUID.t() | nil) :: :ok
  def settle(%Scope{active_project_id: project_id} = scope),
    do: settle(project_id, scope.active_working_copy_id)

  def settle(project_id) when is_binary(project_id), do: settle(project_id, nil)

  def settle(_no_project), do: :ok

  # The reader's vantage rides along, because rows are keyed per working copy
  # and a pass computes one vantage at a time.
  #
  # `Projection.vantages/1` answers the ones that already have rows, which
  # covers every checkout somebody has read before and cannot cover the first
  # read from a new one — a fresh worktree would settle, get a pass that
  # maintains everyone else, and still find nothing of its own. So a reader
  # names the vantage it is about to read and the next pass includes it. After
  # that it has rows and `vantages/1` keeps it.
  #
  # This is not a read computing the graph. The reader asks for nothing to be
  # derived; it says which row-space it cares about, and the watcher decides
  # what to do about it.
  @spec settle(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: :ok
  def settle(project_id, vantage) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, project_id) do
      [{pid, _}] -> GenServer.call(pid, {:settle, vantage}, 30_000)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  What this project's watcher is doing, or `nil` when nothing is watching it.

  For `/dev/state`, which exists because the hard failures this week were all
  the database and the runtime disagreeing — a watcher that did not survive a
  deploy looks exactly like a graph that has not moved, and neither is visible
  from a table.
  """
  @spec status(Ecto.UUID.t()) ::
          %{
            pending: boolean(),
            last_recompute: DateTime.t() | nil,
            last_error: %{at: DateTime.t(), message: String.t()} | nil
          }
          | nil
  def status(project_id) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, project_id) do
      [{pid, _}] -> GenServer.call(pid, :status, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Start a watcher for every project that has an agent in the loop.

  Watchers live in memory, so a restart takes them all — and nothing recreated
  them until somebody toggled a loop. That is the worst possible time to lose
  them: a deploy is exactly when agents are mid-run, and an agent that goes idle
  after one has nothing watching for the work that would wake it.

  Called at boot. A project with nobody working it stays unwatched, which is the
  same rule `ensure_watching/1` follows on demand.

  Best-effort by design: a project whose scope cannot be built is skipped rather
  than taking the boot down with it, and the next stop decision on that project
  starts its watcher anyway.
  """
  @spec watch_active_projects() :: :ok
  def watch_active_projects do
    AgentsRepository.continuous_project_scopes()
    |> Enum.each(fn scope ->
      case ensure_watching(scope) do
        {:ok, _pid} ->
          :ok

        other ->
          Logger.warning(
            "[GraphWatcher] could not watch #{scope.active_project_id}: #{inspect(other)}"
          )
      end
    end)
  end

  # -- Server --

  @impl true
  def init({project_id, scope}) do
    # So `terminate/2` runs and can take this watcher's in-flight wake with it.
    Process.flag(:trap_exit, true)

    GraphInputs.subscribe(project_id)

    # Compute once on arrival, then maintain from events.
    #
    # Reads used to do this implicitly: the first render of a project with no
    # rows found a cache miss and built the whole graph as a side effect of
    # somebody looking. With reads answering from the rows, nothing else ever
    # would — a project that has had no events since it was created would have
    # no graph, and every reader would be handed an empty answer rather than a
    # stale one.
    #
    # Sent rather than done here, because `init/1` blocks the supervisor and
    # this is a whole-project compute on a cold project. Timer nil, so the
    # first real observation still schedules its own pass.
    send(self(), :recompute)

    {:ok,
     %{
       project_id: project_id,
       scope: scope,
       timer: nil,
       pending_observations: [],
       # Vantages a reader has named that may not have rows yet. Seeded with
       # the one this watcher was started with, which is the checkout of
       # whoever asked for it — an agent's worktree, usually.
       requested_vantages: MapSet.new([scope.active_working_copy_id]),
       # Which vantages this watcher has actually computed. Held in memory so
       # `settle/2` can answer "is this reader's row-space new" without asking
       # the database — that question is on the path of every read, which is
       # before every tool call an agent makes.
       known_vantages: MapSet.new(),
       # What was actionable after the last pass, so the next one can tell what
       # *appeared* from what was already there. `nil` means no pass yet.
       last_actionable: nil,
       # What the last pass found that the one before it had not, and when a
       # wake last went out for it. Kept only so `status/1` can say so — the
       # recompute reads neither.
       last_appeared: nil,
       last_wake: nil,
       # The wake this watcher currently has in flight, so stopping the watcher
       # stops it too.
       waking: nil,
       last_recompute: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    report = %{
      pending: state.timer != nil,
      last_recompute: state.last_recompute,
      last_error: state.last_error,
      # The last link in the chain, and the only one that was invisible.
      # "The rows are fresh" is where this process's job ends and where the
      # observable claim does not: an agent is woken because work *appeared*,
      # and a pass that recomputed correctly and woke nobody is both the normal
      # case and the failure case. Reported as counts rather than as the sets,
      # because this is on the path of anything that reads status.
      actionable: state.last_actionable && MapSet.size(state.last_actionable),
      appeared: state.last_appeared,
      last_wake: state.last_wake
    }

    {:reply, report, state}
  end

  def handle_call({:settle, vantage}, _from, state) do
    state = remember_vantage(state, vantage)

    cond do
      state.timer != nil ->
        Process.cancel_timer(state.timer)
        settle_reply(recompute(%{state | timer: nil}))

      # Observations in hand with no timer behind them. A pass that failed
      # keeps its pending list — correctly, it never applied them — but clears
      # the timer, so nothing was left to fire and the queue sat there until
      # some unrelated write happened along. A reader asking to settle is
      # exactly the moment to try again.
      state.pending_observations != [] ->
        settle_reply(recompute(state))

      # Nothing queued, and this reader is asking from a vantage no pass has
      # ever computed. Its row-space is empty and would stay empty, because
      # only a pass writes rows and only an observation schedules a pass.
      new_vantage?(state, vantage) ->
        settle_reply(recompute(state))

      true ->
        {:reply, :ok, state}
    end
  end

  defp settle_reply(result, attempts_left \\ 2)

  defp settle_reply({:ok, state}, _attempts_left), do: {:reply, :ok, state}
  defp settle_reply({:gone, state}, _attempts_left), do: {:stop, :normal, :ok, state}

  # `settle/1` promises the caller that the queue is reconciled before it
  # answers. A pass that lost a race for a connection has reconciled nothing,
  # and answering `:ok` anyway hands back a graph that is exactly as stale as
  # it was — silently, because the caller asked to be current and was told it
  # is.
  #
  # That is not only a test problem, though it showed up as one: three
  # criteria failing on a graph that had not moved, under contention. In
  # production it is an agent asking what to work on and being answered from
  # before the write it is waiting on, whenever the pool happens to be busy.
  #
  # Bounded, because the caller is blocked on this and a pool that is down
  # rather than busy must not hold them forever. When the attempts run out the
  # pass stays scheduled, so the queue is still reconciled — just not before
  # this answer.
  defp settle_reply({:transient, state}, 0), do: {:reply, :ok, state}

  defp settle_reply({:transient, state}, attempts_left) do
    settle_reply(recompute(state), attempts_left - 1)
  end

  defp remember_vantage(state, vantage),
    do: %{state | requested_vantages: MapSet.put(state.requested_vantages, vantage)}

  # From memory, not from a query.
  #
  # This asked `Projection.vantages/1` — one query for the stored vantages plus
  # an existence check per vantage — on every settle, which is every read. A
  # read happens before every Read, Grep and Bash an agent runs, and criterion
  # 2347 measures exactly that budget: it caught this at 2.3 extra queries per
  # tool call.
  #
  # A watcher knows what it has computed, so the common case — a reader whose
  # row-space this watcher already maintains — costs a set lookup and nothing
  # else. A vantage genuinely new still triggers the pass that adds it.
  defp new_vantage?(state, vantage), do: not MapSet.member?(state.known_vantages, vantage)

  @impl true
  # The observation id rides along so the recompute can name what it consumed.
  # Accumulated rather than replaced, because the debounce coalesces a burst
  # into one pass: a recompute answers for every publish since the last one,
  # and listing them is the only way to show that none was dropped.
  def handle_info({:graph_inputs_changed, _project_id, obs}, state) do
    {:noreply, schedule(%{state | pending_observations: add_observation(obs, state)})}
  end

  # A publisher that has not been taught to mint an id yet. Counted as an
  # unnamed observation rather than ignored — the report needs to know it
  # happened, and silently dropping it is how the gap this closes got there.
  def handle_info({:graph_inputs_changed, _project_id}, state) do
    {:noreply, schedule(%{state | pending_observations: add_observation(nil, state)})}
  end

  def handle_info(:recompute, state) do
    case recompute(%{state | timer: nil}) do
      {:ok, state} -> {:noreply, state}
      {:transient, state} -> {:noreply, state}
      {:gone, state} -> {:stop, :normal, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Every observation this watcher received gets named in a line, even when the
  # graph emitted none of its own.
  #
  # Stamping `obs=` as metadata covers the case where the watcher's own pass
  # does the recomputing, and misses the one the architecture says is normal:
  # "every graph computation in this application is triggered by a reader"
  # (`GraphInputs`). A reader that arrives first recomputes in its own process,
  # carrying no metadata, and leaves nothing stale — so the watcher's pass logs
  # nothing, clears its pending list, and the ids vanish.
  #
  # Measured the first time the report ran against live traffic: `dc63ca83`
  # announced at 16:31:01, applied by a reader's recompute nine seconds later,
  # and named by nothing. Reported as dropped, which was the right answer to
  # the question asked — unaccounted-for and ignored are the same thing to
  # anyone reading the log afterwards.
  #
  # So this closes the books rather than describing the work: it says which
  # observations this pass answered for, whatever did the computing.
  defp account_for([]), do: :ok

  defp account_for(consumed) do
    Logger.info("[GraphWatcher] accounted for #{length(consumed)} observation(s)")
  end

  # How the event-based projection is doing, measured against the one this pass
  # just wrote.
  #
  # Here rather than inside the computation because this is the moment both
  # systems have answered the same traffic: the fingerprints have decided and
  # written, and the projector is asked to finish anything still in flight
  # before the comparison — otherwise a mark mid-drain reports as a difference
  # and the number would be about timing rather than coverage.
  #
  # Once per vantage, because a projection is per row-space and comparing
  # across them would mix two populations.
  defp report_shadow(%{scope: %Scope{} = scope} = state, computed) do
    if Shadow.enabled?() do
      ShadowProjector.settle(state.project_id)

      Enum.each(computed, fn vantage ->
        %Scope{scope | active_working_copy_id: vantage}
        |> Shadow.diff()
        |> Shadow.log()
      end)
    end

    :ok
  end

  defp add_observation(obs, %{pending_observations: pending}) do
    [obs || "unnamed" | pending]
  end

  # `none` rather than an empty string, because a recompute with nothing
  # pending is a real and interesting answer: it ran without any observation
  # asking it to, which is exactly the case the counts could never distinguish
  # from a busy one.
  defp observation_tag([]), do: "none"
  defp observation_tag(ids), do: Enum.join(ids, ",")

  # Already scheduled means already covered. Not restarting the timer is what
  # makes this coalescing rather than throttling: a steady stream of writes
  # still gets a pass every window, where extending on each event would
  # mean a busy project never recomputes at all.
  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :recompute, debounce_ms())}

  defp schedule(state), do: state

  # The row-spaces this pass is responsible for: the ones that already have
  # rows, plus any a reader has named since the last pass. `nil` is always in
  # the first set — `Projection.vantages/1` puts it there — because it is what
  # every reader that is not an agent resolves to.
  # Filtered through `live_vantages/2` rather than merely unioned, because a
  # reader can name a checkout that is offboarded before the next pass runs.
  # Computing for a copy that no longer exists raises on the `requirement_graphs`
  # foreign key, and the watcher reports that as a fault forever after.
  defp vantages(state) do
    Projection.live_vantages(
      state.scope,
      Enum.concat(Projection.vantages(state.scope), state.requested_vantages)
    )
  end

  defp recompute_vantage(%{scope: %Scope{} = scope}, vantage) do
    {_graph, actionable, _computed_at} =
      RequirementGraph.recompute(%Scope{scope | active_working_copy_id: vantage})

    actionable
  end

  # The owner columns, and only those. Any other constraint is a real defect
  # and must still be reported.
  @owner_constraints ~w(working_copy_id_fkey component_id_fkey story_id_fkey project_id_fkey)

  defp entity_gone?(error) do
    constraint = constraint_of(error)
    is_binary(constraint) and Enum.any?(@owner_constraints, &String.contains?(constraint, &1))
  end

  defp constraint_of(%Postgrex.Error{postgres: %{constraint: constraint}}), do: constraint
  defp constraint_of(_error), do: nil

  # Waking is a consequence of the graph moving, not of a pass running.
  #
  # These were one thing and that conflation is why the graph could not be told
  # about an analyzer finishing. Announcing is how a writer says "an input
  # moved"; every announcement should recompute, because recomputing is cheap
  # and per-entity and the answer is wrong until it happens. Waking is a far
  # more expensive act — it renders every role's menu and dispatches to agents
  # — and it is only warranted when a real input moved.
  #
  # Coupling them meant the cost of waking vetoed recomputing. A stop hook
  # records an analyzer run on every agent turn, so `Analysis` announcing woke
  # every role every turn — a real storm, and the reason announcing was dropped.
  # With the two separated it recomputes every turn, which is correct and
  # bounded, and wakes nobody unless something actually moved.
  #
  # Gated on `consumed != []` (see `recompute/1`), not on the requirement
  # actionable-set changing. That set is only one of the things a role's menu
  # can show — problems are coding work the graph never carries as a
  # requirement (3193), and a wake gated on the actionable diff never ran for
  # one. Widening the trigger to "a real observation landed" rather than
  # adding a second, parallel diff for problems (a proxy per writer, the shape
  # this module's own moduledoc says it moved away from) means one signal
  # decides whether to ask, and `Menu.render/4` — already correct, already
  # silent when a role has nothing — decides whether to say anything. The
  # extra cost is a rendered menu per continuous agent on a pass that changed
  # requirements not at all; the message count for that case is unchanged,
  # because `Menu.render/4` was always going to answer `""` for it.
  #
  # `appeared` below still exists for `last_appeared`'s diagnostic value, not
  # for the wake decision. A first pass still shows an empty `appeared` — the
  # requirements it finds were already actionable before this watcher existed,
  # criterion 3186 — even though the same pass's `consumed` is what actually
  # gates the wake.
  defp newly_actionable(actionable, nil), do: {keys(actionable), []}

  defp newly_actionable(actionable, previous) do
    now = keys(actionable)
    {now, MapSet.to_list(MapSet.difference(now, previous))}
  end

  defp keys(actionable),
    do: MapSet.new(actionable, &{&1.entity_type, &1.entity_id, &1.name})

  defp maybe_wake(_state, []), do: nil

  defp maybe_wake(state, _appeared) do
    scope = state.scope

    case Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
           CodeMySpec.Agents.wake_project_roles(scope)
         end) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp recompute(state) do
    refuse_if_faulted(state.project_id)

    # Stamped as metadata rather than threaded as an argument, so every line
    # the computation emits carries it without `RequirementGraph` having to
    # know this process exists. `config/config.exs` lists `:obs` for the same
    # reason it lists `:cms_project`.
    consumed = Enum.reverse(state.pending_observations)
    Logger.metadata(obs: observation_tag(consumed))

    # Recompute, then read. These were one call until the read stopped
    # recomputing — a reader repairing the graph is what made a silent writer
    # indistinguishable from a working one. The watcher is the write path, so
    # it asks for the work explicitly.
    #
    # Once per vantage, because rows are keyed per working copy and a pass
    # computes exactly one row-space. This process is per *project* and held a
    # single scope, so it maintained whichever checkout started it and left
    # every other one frozen — including `nil`, which is what every reader that
    # is not an agent resolves to. Reads used to cover for that by rebuilding
    # their own row-space on the way past; they no longer do, so the write path
    # has to maintain all of them.
    # Flattened, so waking asks "did any vantage produce work" rather than
    # "did mine". `wake_project_roles/2` is menu-gated, so a role with nothing
    # to do is not charged a turn — over-waking costs a rendered menu and
    # under-waking is the ninety minutes of silence this exists to end.
    computed = vantages(state)

    # Measured here rather than around the whole clause, because the clause also
    # broadcasts, wakes agents and reports the shadow — work this pass does
    # *because* the graph moved, not work the graph cost. A number that included
    # waking would grow with the number of agents connected and say nothing
    # about the project's size.
    actionable =
      DrainCost.measure(
        %{
          kind: :pass,
          project_id: state.project_id,
          observations: length(consumed),
          vantages: length(computed)
        },
        fn -> {Enum.flat_map(computed, &recompute_vantage(state, &1)), %{}} end
      )

    account_for(consumed)
    report_shadow(state, computed)

    # Only when an input actually moved. A pass that ran purely to onboard a
    # vantage a reader named for the first time (`consumed == []`, including
    # the very first pass this watcher ever runs) computed rows nobody had
    # yet -- not a change to anything already on the board. That is the same
    # distinction `newly_actionable/2` below already draws for waking: the
    # first pass wakes nobody because everything it finds was already
    # actionable before this watcher existed. Announcing unconditionally
    # meant a reader visiting a fresh checkout looked exactly like a graph
    # change to anyone counting announcements, and nothing downstream could
    # tell the two apart.
    if consumed != [] do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        GraphInputs.topic(state.project_id),
        {:graph_updated, state.project_id}
      )
    end

    # Nothing actionable is a real answer and not a reason to wake anybody:
    # `wake/2` would render an empty menu and stay silent for every role, so
    # this only saves the work of asking.
    #
    # Off this process, and that is not an optimisation. Waking renders each
    # role's menu, the menu counts requirements, and counting them can call
    # `settle/1` — which is a call to this process. A watcher waking inside its
    # own recompute would be calling itself, and the agent that had been waiting
    # would be waiting on a deadlock.
    {now_actionable, appeared} = newly_actionable(actionable, state.last_actionable)
    waking = maybe_wake(state, consumed)

    {:ok,
     %{
       state
       | last_recompute: DateTime.utc_now(),
         last_error: nil,
         pending_observations: [],
         # Every requested vantage has rows now, so `Projection.vantages/1`
         # keeps them from here without this list growing forever.
         requested_vantages: MapSet.new(),
         known_vantages: MapSet.union(state.known_vantages, MapSet.new(computed)),
         last_actionable: now_actionable,
         last_appeared: Enum.map(appeared, fn {type, _id, name} -> "#{type}:#{name}" end),
         last_wake: if(waking, do: DateTime.utc_now(), else: state.last_wake),
         waking: waking
     }}
  rescue
    error ->
      recompute_failure(state, error)
  end

  # The one thing a recompute could not be made to do: fail for a reason that is
  # actually a fault.
  #
  # `3ad5e45c` closed a day of looking with "every remaining path either
  # succeeds or means the project is gone" — `Preloader.load/1` is `Repo.all`,
  # the file side channel is gone, and `wake_project_roles/1` runs in a Task
  # whose failures never reach the rescue below. The machinery criterion 3248
  # describes is real and right: a genuine fault logs at `:error` and lands on
  # `status/1` as `last_error`, which the requirements graph page renders.
  # Nothing exercised it, and the seam that looked like one turned out to be
  # completion.
  #
  # That issue named two ways forward and asked for a decision. This is the
  # second: a deliberate fault, keyed on the project so it reaches one watcher.
  #
  # A raise rather than an error tuple, because the thing under test is the
  # `rescue` — a recompute that fails is an exception escaping
  # `cached_graph_with_actionable/1`, and a seam that returned a tuple would
  # exercise a path production never takes.
  #
  # Note for anyone injecting this during a spex rather than live: the failure
  # logs at `:error`, and `SexySpex.ErrorCapture` fails a run on any logged
  # error — including one from a straggler watcher landing in somebody else's
  # spex. That is the same crossfire this issue records.
  defp refuse_if_faulted(project_id) do
    raise_if(Faults.active?(project_id, :graph_recompute_fails))
  end

  defp raise_if(false), do: :ok

  defp raise_if(true) do
    raise RuntimeError, "graph recompute failed (fault injected for this project)"
  end

  # A watcher whose project is gone has finished, not failed.
  #
  # Both halves of this matter, and only one of them is about production.
  #
  # A deleted project leaves a watcher running for it, and every event it hears
  # raises on `project_configurations_project_id_fkey` when
  # `Configurations.get_or_create/1` tries to insert. Logging that forever says
  # something is wrong when the truth is there is nothing left to do.
  #
  # The half that bites harder is under test. A watcher outlives the spex that
  # started it, and the sandbox transaction rolls back at the end of the test —
  # so the project vanishes underneath a process that is still running and the
  # next pass raises exactly the same way. `SexySpex.ErrorCapture` installs a
  # handler on `:logger` globally, so an `:error` from that straggler fails
  # whichever spex happens to be running when it lands. Escalating this line
  # from `:warning` to `:error` turned a silent race into an intermittent
  # failure in unrelated specs, and the promote gate caught it on criterion
  # 5887 of story 559, which touches none of this.
  #
  # Stopping is right for both: there is no project, so there is nothing to
  # recompute, and a `:transient` child that stops `:normal` is not restarted.
  # Something this pass was computing for went away while it computed.
  #
  # A pass reads a context, spends real time building a graph from it, and then
  # writes — so anything in that snapshot can be deleted underneath it. Two
  # seen: a checkout offboarded mid-pass, and a component replaced by a sync
  # (renaming a spec's module deletes the old component and creates a new one,
  # which is criterion 5931). Both land as a foreign key refusing a row whose
  # owner no longer exists, and neither is a fault — `last_error` shows on
  # `/dev/state`, and a watcher reporting a fault every time somebody renames a
  # module is a diagnostic nobody reads.
  #
  # The delete announced, so another pass is already queued; this one schedules
  # anyway, because the announcement may have landed while this pass was in
  # flight and been folded into the list it is about to retry.
  defp recompute_failure(state, error) do
    entity_gone?(error)
    |> handle_failure(state, error)
  end

  defp handle_failure(true, state, error) do
    Logger.info(
      "[GraphWatcher] a pass for #{state.project_id} raced a delete " <>
        "(#{constraint_of(error)}); retrying with a context that has the news"
    )

    {:ok, schedule(state)}
  end

  defp handle_failure(false, state, error) do
    transient?(error)
    |> handle_transient(state, error)
  end

  # The pool was busy. That is not "the graph has stopped being able to
  # compute", which is what this watcher's `:error` means and what
  # `/dev/state` renders it as — and under contention it is common: a pass
  # losing a race for a connection for 360ms.
  #
  # Logging it as a fault had a second cost that took a while to see.
  # `SexySpex.ErrorCapture` fails a run on any logged `:error`, so a watcher
  # saying this during somebody else's scenario failed that scenario. Every
  # analyzer sweep on a loaded box came back with exactly three casualties,
  # different ones each time, which reads as three flaky spex and is one
  # watcher shouting.
  #
  # Rescheduled like any other failure, so the observations it did not apply
  # are retried rather than stranded.
  defp handle_transient(true, state, error) do
    Logger.warning(
      "[GraphWatcher] a pass for #{state.project_id} could not get what it needed " <>
        "(#{Exception.message(error)}); retrying"
    )

    {:transient, schedule(state)}
  end

  defp handle_transient(false, state, error), do: real_failure(state, error)

  # Contention, not a defect: the pool refusing a checkout, or a query giving
  # up waiting for one.
  defp transient?(%DBConnection.ConnectionError{}), do: true
  defp transient?(%DBConnection.OwnershipError{}), do: true
  defp transient?(_error), do: false

  defp real_failure(state, error) do
    if project_exists?(state.project_id) do
      # Loud, and still alive.
      #
      # Loud because a recompute that fails and says nothing is the worst shape
      # this whole story guards against: every reader goes on being served the
      # last good answer, which is correct-looking and frozen, and the only
      # symptom is agents working from a graph that stopped moving. `:error`
      # because that is the level somebody looks at, and on `status/1` because a
      # log is not somewhere anybody looks *at a particular project*.
      #
      # Alive because the project is still there to serve. The next event
      # schedules another pass and a reader still computes on demand, so nothing
      # is retried quietly and nothing is lost.
      Logger.error(
        "[GraphWatcher] recompute failed for #{state.project_id}: " <> Exception.message(error)
      )

      # And try again, because the observations this pass did not apply are
      # still in hand and nothing else will fire for them. Without this a
      # single transient failure — a connection checkout losing a race for the
      # pool, which is what this looks like under load — strands every pending
      # observation until the next unrelated write, and the graph stops moving
      # while looking perfectly healthy.
      #
      # Through `schedule/1`, so the retry coalesces with anything that arrives
      # meanwhile and a project failing repeatedly costs one pass per window
      # rather than a spin.
      {:ok,
       schedule(%{
         state
         | last_error: %{at: DateTime.utc_now(), message: Exception.message(error)}
       })}
    else
      Logger.info("[GraphWatcher] stopping: project #{state.project_id} no longer exists")

      {:gone, state}
    end
  end

  # Gone means the query answered, and answered no. There is no third answer
  # here, and there used to be: this rescued every exception to `false`, so a
  # DBConnection queue timeout read as "the project is gone". That retires the
  # watcher, `:transient` means a `:normal` stop is never restarted, and
  # `settle/1` answers `:ok` when nothing is watching — one transient blip
  # retired a project's watcher permanently and every read after it was served
  # a frozen graph, silently.
  #
  # No rescue at all now. If the question cannot be asked, this raises, the
  # watcher dies abnormally, and `:transient` restarts it — which is the
  # recovery we actually want: a fresh watcher computes on arrival, so the
  # graph is rebuilt rather than frozen. Deciding on a guess was the only thing
  # that could lose work here.
  defp project_exists?(project_id) do
    Repo.exists?(from(p in "projects", where: p.id == type(^project_id, :binary_id)))
  end
end
