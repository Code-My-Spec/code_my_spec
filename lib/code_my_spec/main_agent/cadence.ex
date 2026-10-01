defmodule CodeMySpec.MainAgent.Cadence do
  @moduledoc """
  Wakes a project's main agent on an interval, with the digest in hand.

  Story 1059. The cadence is a pull, and that is the whole design: every other
  way the main agent learns anything needs the agent in trouble to still be
  working well enough to say so, and the failure worth catching is exactly the
  one where it is not. One outage was visible only because the affected agent
  could still call `send_message` — had it lost that too, it would have sat
  silent indefinitely.

  ## One turn a tick, continuous main only

  John: "Cadence is for continuous main agents only." Each tick gives a
  running, continuous main exactly one turn (`Wake` event `:cadence`), work or
  no work: the digest, led by what waits on it, with its own work offer folded
  in. A non-continuous main gets nothing from the timer; a main mid-turn or
  waiting on its own run is skipped until the next tick.

  ## A floor, not a schedule

  Criterion 3318. The cadence is the longest anything can go unseen, never the
  soonest: a question raised now is pushed now (story 1053's 3265), and leaning
  on the next tick would turn a blocked agent's wait into a whole interval.

  ## Stopping is a decision, and it does not close the door

  The timer stops when the main agent taps out — criterion 3334 — because a
  model call every interval to look at a finished fleet is spend with nothing
  behind it, and a loop that cannot stop is one somebody ends up supervising.

  What stops is the timer and only the timer. 3335: an agent's question still
  reaches a stood-down main agent, because the alternative has no symptom on
  either side — it is not woken, which is what it asked for, and the question
  simply never arrives.
  """

  use GenServer

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Configurations
  alias CodeMySpec.Faults
  alias CodeMySpec.MainAgent
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.Users.Scope

  @registry CodeMySpec.MainAgent.CadenceRegistry

  # -- the interval -----------------------------------------------------------

  @doc """
  How often this project's main agent is woken, in seconds.

  Configured rather than compiled, which is criterion 3331. It is the one number
  that trades the feature's two costs against each other and the right value is
  not knowable in advance: too long and a stalled agent burns most of a window
  before anybody looks, too short and the check-ins cost more than they find on
  a machine that is also running the agents.

  Twenty minutes is what the person doing this by hand settled on — a starting
  guess. In code it would be a deploy to change, which in practice means never.
  """
  @spec interval(Scope.t()) :: pos_integer()
  def interval(%Scope{} = scope), do: Configurations.main_agent_cadence_seconds(scope)

  @doc """
  Set how often this project's main agent is woken.

  A row on the project's configuration, beside every other per-project setting.
  It used to be `Application.put_env/3` — shared mutable state for the whole
  node, lost on every restart, and reachable without a scope. QA found it: a
  deliberately set interval silently reverted to the default at the next boot,
  which is worse than never having offered the setting, because the operator
  believes it is in force.
  """
  @spec set_interval(Scope.t(), pos_integer()) :: :ok | {:error, Ecto.Changeset.t()}
  def set_interval(%Scope{} = scope, seconds) when is_integer(seconds) and seconds > 0 do
    case Configurations.update(scope, %{main_agent_cadence_seconds: seconds}) do
      {:ok, _configuration} ->
        case Registry.lookup(@registry, scope.active_project_id) do
          [{pid, _}] -> GenServer.cast(pid, :reschedule)
          [] -> :ok
        end

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # -- running ----------------------------------------------------------------

  @doc """
  Whether this project's main agent is still *meant* to be woken.

  Intent, not fact. Read from the stopped set rather than from a process, so the
  answer survives the server being restarted for reasons that have nothing to do
  with the main agent's decision. A tap-out is a decision; a supervisor restart
  is not, and a decision that a restart silently reverses is one nobody made.

  It answers "has this project stood down", and `check_in/1` is right to branch
  on it — by the time a check-in runs, the process asking is the timer itself,
  so existence is not in question there.

  It is **not** the health signal it reads as, and that is how nothing starting
  the cadence went unnoticed: this answered true for every project that had
  never stood down, including every project with no timer at all. `alive?/1` is
  the question about fact.
  """
  @spec running?(Scope.t()) :: boolean()
  def running?(%Scope{active_project_id: project_id}) do
    project_id not in Application.get_env(:code_my_spec, :main_agent_stood_down, [])
  end

  @doc """
  Whether a timer actually exists for this project right now.

  The counterpart to `running?/1`, which is about intent. Both are needed and
  they disagree in exactly the case worth catching: meant to be woken, and
  nothing there to wake it.
  """
  @spec alive?(Scope.t()) :: boolean()
  def alive?(%Scope{active_project_id: nil}), do: false

  def alive?(%Scope{active_project_id: project_id}) do
    Registry.lookup(@registry, project_id) != []
  end

  def last_check(%Scope{active_project_id: project_id}) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> GenServer.call(pid, :last_check)
      [] -> nil
    end
  end

  @doc "Stop waking this project's main agent, because it has stood down."
  @spec stand_down(Scope.t()) :: :ok
  def stand_down(%Scope{active_project_id: project_id}) do
    stood_down = Application.get_env(:code_my_spec, :main_agent_stood_down, [])

    Application.put_env(
      :code_my_spec,
      :main_agent_stood_down,
      Enum.uniq([project_id | stood_down])
    )

    :ok
  end

  @doc "Start waking it again."
  @spec resume(Scope.t()) :: :ok
  def resume(%Scope{active_project_id: project_id}) do
    stood_down = Application.get_env(:code_my_spec, :main_agent_stood_down, [])
    Application.put_env(:code_my_spec, :main_agent_stood_down, stood_down -- [project_id])

    :ok
  end

  # -- the process ------------------------------------------------------------

  def start_link(%Scope{} = scope) do
    GenServer.start_link(__MODULE__, scope, name: via(scope.active_project_id))
  end

  @doc """
  Start this project's cadence if it is not already running.

  The same shape `GraphWatcher.ensure_watching/1` uses, and for the same reason:
  a project nobody is working on needs no timer, so one is started on demand
  rather than one per project at boot.

  QA found this missing entirely — the GenServer was written, and nothing
  anywhere called `start_link/1`. No `:check_in` message was ever sent, so the
  story's whole promise — a problem surfacing even when the agent in trouble
  cannot say so — never happened.

  What hid it is worth keeping: `running?/1` answered **true** throughout,
  because it reads the stood-down set and no project had stood down. The one
  signal that looked like health was reporting intent. The spex did not catch it
  either, because they start the process themselves — which proves the loop
  works once started and can say nothing about whether anything starts it.
  """
  @spec ensure_running(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_running(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_running(%Scope{} = scope) do
    case DynamicSupervisor.start_child(
           CodeMySpec.MainAgent.CadenceSupervisor,
           {__MODULE__, cadence_scope(scope)}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # The scope outlives the request that started the timer, so it keeps only what
  # a check-in needs and none of the caller's session — a cadence holding a
  # `conn`-shaped scope would be waking on behalf of whoever happened to be
  # first.
  defp cadence_scope(%Scope{} = scope) do
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
  Re-establish cadences for whatever was already being worked.

  Timers are in memory, so a restart takes them all — and a deploy is exactly
  when agents are mid-run. Without this, a project whose agents were running
  before the restart would never be looked in on again until somebody happened
  to touch it.

  Seeded from projects with a `main` agent running, not from projects with
  continuous agents. QA found what the old trigger cost: twelve agents running
  on this project, one of them `main`, posting real messages minutes apart —
  and `continuous = false` on every one of them, so `running: no` roughly twenty
  minutes after a boot that was supposed to have re-established it (`11aea8f5`).
  "Nothing is in a loop" was standing in for "there is nobody to look in on",
  and they are not the same statement.
  """
  @spec wake_active_projects() :: :ok
  def wake_active_projects do
    AgentsRepository.main_agent_project_scopes()
    |> Enum.each(fn scope ->
      case ensure_running(scope) do
        {:ok, _pid} ->
          :ok

        other ->
          Logger.warning("[Cadence] could not wake #{scope.active_project_id}: #{inspect(other)}")
      end
    end)
  end

  defp via(project_id), do: {:via, Registry, {@registry, project_id}}

  @impl true
  def init(%Scope{} = scope) do
    {:ok, schedule(%{scope: scope, last_check: nil, stalled: MapSet.new()})}
  end

  @impl true
  def handle_call(:last_check, _from, state), do: {:reply, state.last_check, state}

  # One turn for a continuous main, with the digest and its work offer
  # (`MainAgent.cadence_check_in/3`). A question raised between ticks reaches
  # it at once through `MainAgent.question_raised/2`, not through here.
  @impl true
  def handle_info(:check_in, state) do
    digest = digest(state.scope)
    {newly, stalled} = stall_transitions(state.stalled, digest)
    state = %{state | stalled: stalled}

    _ = MainAgent.cadence_check_in(state.scope, digest, newly)
    checked_at = DateTime.utc_now()

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "cadence:checks",
      {:recovery_checked, state.scope.active_project_id, checked_at}
    )

    {:noreply, schedule(%{state | last_check: checked_at})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Which teammates have just stalled, and the stalled set to remember.

  Step 4b (a31f1cd6): main is told on the transition into stalled, once, not
  every check-in. An agent that recovers leaves the set, so stalling again is a
  new transition. A digest that could not be built changes nothing.
  """
  @spec stall_transitions(MapSet.t(String.t()), Digest.t()) ::
          {[AgentWork.t()], MapSet.t(String.t())}
  def stall_transitions(seen, %Digest{failed: reason}) when is_binary(reason), do: {[], seen}

  def stall_transitions(seen, %Digest{} = digest) do
    stalled = Digest.stalled(digest)
    newly = Enum.reject(stalled, &MapSet.member?(seen, &1.agent_id))
    {newly, MapSet.new(stalled, & &1.agent_id)}
  end

  @doc "Tell main about each teammate that has just stalled (`:teammate_stalled`)."
  @spec announce_stalls(Scope.t(), [AgentWork.t()]) :: :ok
  def announce_stalls(%Scope{} = scope, entries) do
    Enum.each(entries, fn entry ->
      Agents.notify_main(
        scope,
        :teammate_stalled,
        "Teammate stalled: the #{entry.role} agent #{entry.agent_id} on working copy " <>
          "#{entry.working_copy_id}#{root(entry.working_copy_root)} — " <>
          AgentWork.unclaimed_work(entry)
      )
    end)
  end

  defp root(nil), do: ""
  defp root(path), do: " (#{path})"

  @impl true
  def handle_cast(:reschedule, state) do
    Process.cancel_timer(state.timer)
    {:noreply, schedule(state)}
  end

  # Coalescing rather than extending, the same shape `GraphWatcher` uses: the
  # next wake-up is one interval from this one, whatever happened in between.
  defp schedule(state) do
    Map.put(
      state,
      :timer,
      Process.send_after(self(), :check_in, interval(state.scope) * 1000)
    )
  end

  @doc """
  What the main agent is handed, or why it could not be assembled.

  Every source is read here and a failure in any of them is the digest's
  failure, not a shorter list. Criterion 3333: an empty digest and an
  unbuildable one say the same thing to a reader, and only one of them is good
  news.
  """
  @spec digest(Scope.t()) :: Digest.t()
  def digest(%Scope{} = scope) do
    if Faults.active?(scope.active_project_id, :digest_unavailable) do
      Digest.failed("the analyzer ledger did not answer")
    else
      %Digest{
        work: MainAgent.list_agent_work(scope),
        off: MainAgent.list_off_agents(scope),
        machinery: MainAgent.check_machinery(scope),
        questions: MainAgent.list_open_questions(scope)
      }
    end
  end
end
