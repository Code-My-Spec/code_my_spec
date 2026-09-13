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
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

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
    case DynamicSupervisor.start_child(
           CodeMySpec.Requirements.WatcherSupervisor,
           {__MODULE__, {project_id, watcher_scope(scope)}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
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
  def settle(%Scope{active_project_id: project_id}), do: settle(project_id)

  def settle(project_id) when is_binary(project_id) do
    case Registry.lookup(CodeMySpec.Requirements.Registry, project_id) do
      [{pid, _}] -> GenServer.call(pid, :settle, 30_000)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def settle(_no_project), do: :ok

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
    GraphInputs.subscribe(project_id)

    {:ok,
     %{
       project_id: project_id,
       scope: scope,
       timer: nil,
       last_recompute: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    report = %{
      pending: state.timer != nil,
      last_recompute: state.last_recompute,
      last_error: state.last_error
    }

    {:reply, report, state}
  end

  def handle_call(:settle, _from, %{timer: nil} = state), do: {:reply, :ok, state}

  def handle_call(:settle, _from, %{timer: timer} = state) do
    Process.cancel_timer(timer)

    case recompute(%{state | timer: nil}) do
      {:ok, state} -> {:reply, :ok, state}
      {:gone, state} -> {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def handle_info({:graph_inputs_changed, _project_id}, state) do
    {:noreply, schedule(state)}
  end

  def handle_info(:recompute, state) do
    case recompute(%{state | timer: nil}) do
      {:ok, state} -> {:noreply, state}
      {:gone, state} -> {:stop, :normal, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Already scheduled means already covered. Not restarting the timer is what
  # makes this coalescing rather than throttling: a steady stream of writes
  # still gets a pass every window, where extending on each event would
  # mean a busy project never recomputes at all.
  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :recompute, debounce_ms())}

  defp schedule(state), do: state

  defp recompute(state) do
    refuse_if_faulted(state.project_id)

    {_graph, actionable, _computed_at} =
      RequirementGraph.cached_graph_with_actionable(state.scope)

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      GraphInputs.topic(state.project_id),
      {:graph_updated, state.project_id}
    )

    # Nothing actionable is a real answer and not a reason to wake anybody:
    # `wake/2` would render an empty menu and stay silent for every role, so
    # this only saves the work of asking.
    #
    # Off this process, and that is not an optimisation. Waking renders each
    # role's menu, the menu counts requirements, and counting them can call
    # `settle/1` — which is a call to this process. A watcher waking inside its
    # own recompute would be calling itself, and the agent that had been waiting
    # would be waiting on a deadlock.
    case actionable do
      [] ->
        :ok

      _ ->
        scope = state.scope

        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          CodeMySpec.Agents.wake_project_roles(scope)
        end)
    end

    {:ok, %{state | last_recompute: DateTime.utc_now(), last_error: nil}}
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
  defp recompute_failure(state, error) do
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

      {:ok, %{state | last_error: %{at: DateTime.utc_now(), message: Exception.message(error)}}}
    else
      Logger.info("[GraphWatcher] stopping: project #{state.project_id} no longer exists")

      {:gone, state}
    end
  end

  # Answers false when the question cannot be asked either — a connection that
  # has gone with the project is the same answer for this purpose, and raising
  # here would replace the error being classified with a less useful one.
  defp project_exists?(project_id) do
    Repo.exists?(from(p in "projects", where: p.id == type(^project_id, :binary_id)))
  rescue
    _ -> false
  end
end
