defmodule CodeMySpec.Agents.Main.Cadence do
  @moduledoc """
  Wakes a project's main agent on an interval, with the digest in hand.

  The cadence is a pull: every other way the main agent learns anything needs
  the agent in trouble to still be able to say so, and the failure worth
  catching is the one where it cannot.

  ## Inspect every tick; admit a turn only when needed

  Each tick builds the digest and calls `MainAgent.cadence_check_in/3`. A
  running continuous main receives a turn only for eligible work or something
  needing attention; every other agent gets the recovery check. Empty checks
  preserve the timer, agent intent and conversations.

  ## A floor, not a schedule

  The interval is the longest anything can go unseen, never the soonest: a
  question raised now is pushed now (`MainAgent.question_raised/2`).

  ## Standing down

  A main agent that asks not to be woken stands the project down
  (`stand_down/1`, through its cadence tool): the timer keeps ticking, but main
  gets no turn from it. Questions still reach a stood-down main — one that
  never arrives has no symptom on either side.

  See knowledge/agents, "The cadence".
  """

  use GenServer

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Configurations
  alias CodeMySpec.Faults
  alias CodeMySpec.Requirements
  alias CodeMySpec.Users.Scope

  @registry CodeMySpec.Agents.Main.CadenceRegistry

  # -- the interval -----------------------------------------------------------

  @doc """
  How often this project's main agent is woken, in seconds.

  A per-project configuration row, not a compiled constant: it trades a
  stalled agent going unseen against check-ins costing more than they find,
  and the right value is not knowable in advance.
  """
  @spec interval(Scope.t()) :: pos_integer()
  def interval(%Scope{} = scope), do: Configurations.main_agent_cadence_seconds(scope)

  @doc """
  Set how often this project's main agent is woken.

  A row on the project's configuration, so it survives a restart. A running
  timer is rescheduled.
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

  It answers "has this project stood down", which is what
  `MainAgent.cadence_check_in/3` branches on. It is **not** a health signal: it
  answers true for a project with no timer at all. `alive?/1` is the question
  about fact.
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

  Started on demand, like `GraphWatcher.ensure_watching/1`: a project nobody
  is working on needs no timer. Called when a main agent starts, when
  continuous mode is switched on, at boot (`wake_active_projects/0`), and from
  the harness channel and the cadence tool.
  """
  @spec ensure_running(Scope.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_running(%Scope{active_project_id: nil}), do: {:error, :no_project}

  def ensure_running(%Scope{} = scope) do
    case DynamicSupervisor.start_child(
           CodeMySpec.Agents.Main.CadenceSupervisor,
           {__MODULE__, cadence_scope(scope)}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # The scope outlives the request that started the timer, so it keeps only
  # what a check-in needs and none of the caller's session.
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

  Seeded from projects with an on-duty `main` agent — not from continuous
  agents: "nothing is in a loop" is not "there is nobody to look in on".
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

  Main is told on the transition into stalled, once, not every check-in. An agent that recovers leaves the set, so stalling again is a
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

  @doc """
  Tell main about each teammate that has just stalled (`:teammate_stalled`),
  each recorded as a `:stalled` offer on `{"agent", id}`.
  """
  @spec announce_stalls(Scope.t(), [AgentWork.t()]) :: :ok
  def announce_stalls(%Scope{} = scope, entries) do
    Enum.each(entries, fn entry ->
      Agents.notify_main(
        scope,
        :teammate_stalled,
        "Teammate stalled: the #{entry.role} agent #{entry.agent_id} on working copy " <>
          "#{entry.working_copy_id}#{root(entry.working_copy_root)} — " <>
          AgentWork.unclaimed_work(entry),
        offer: {:stalled, {"agent", entry.agent_id}}
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

  A failure in any source is the digest's failure, not a shorter list: an
  empty digest and an unbuildable one read the same, and only one is good news.
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
        questions: on_duty_questions(scope),
        requirements: requirements_summary(scope),
        completions: CodeMySpec.Agents.CompletionHandoffs.pending(scope)
      }
    end
  end

  # Questions whose asker is on duty: one an off or retired agent raised waits
  # on nothing main can move, and counting it keeps a settled fleet reading as
  # needing attention. `list_notifications` still lists them all.
  defp on_duty_questions(scope) do
    on_duty = scope |> Agents.list_on_duty() |> MapSet.new(& &1.id)
    scope |> MainAgent.list_open_questions() |> Enum.filter(&MapSet.member?(on_duty, &1.agent_id))
  end

  defp requirements_summary(scope) do
    {graph, metadata} = Requirements.project_graph_with_actionable_metrics(scope)
    requirements_summary(graph, metadata)
  rescue
    exception -> {:unavailable, Exception.message(exception)}
  end

  defp requirements_summary(_graph, %{served_from: "empty"}),
    do: {:unavailable, "the project graph has not been published"}

  defp requirements_summary(%{nodes: nodes}, _metadata),
    do: %{total: length(nodes), satisfied: Enum.count(nodes, & &1.satisfied)}
end
