defmodule CodeMySpec.MainAgent.Cadence do
  @moduledoc """
  Wakes a project's main agent on an interval, with the digest in hand.

  Story 1059. The cadence is a pull, and that is the whole design: every other
  way the main agent learns anything needs the agent in trouble to still be
  working well enough to say so, and the failure worth catching is exactly the
  one where it is not. One outage was visible only because the affected agent
  could still call `send_message` — had it lost that too, it would have sat
  silent indefinitely.

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

  alias CodeMySpec.MainAgent
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.Users.Scope

  @registry CodeMySpec.MainAgent.CadenceRegistry
  @default_interval_seconds 20 * 60

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
  def interval(%Scope{active_project_id: project_id}) do
    :code_my_spec
    |> Application.get_env(:main_agent_cadence, %{})
    |> Map.get(project_id, @default_interval_seconds)
  end

  @doc "Set how often this project's main agent is woken."
  @spec set_interval(Scope.t(), pos_integer()) :: :ok
  def set_interval(%Scope{active_project_id: project_id}, seconds)
      when is_integer(seconds) and seconds > 0 do
    intervals = Application.get_env(:code_my_spec, :main_agent_cadence, %{})

    Application.put_env(
      :code_my_spec,
      :main_agent_cadence,
      Map.put(intervals, project_id, seconds)
    )

    :ok
  end

  # -- running ----------------------------------------------------------------

  @doc """
  Whether this project's cadence is still waking its main agent.

  Read from the stopped set rather than from a process, so the answer survives
  the server being restarted for reasons that have nothing to do with the main
  agent's decision. A tap-out is a decision; a supervisor restart is not, and a
  decision that a restart silently reverses is one nobody made.
  """
  @spec running?(Scope.t()) :: boolean()
  def running?(%Scope{active_project_id: project_id}) do
    project_id not in Application.get_env(:code_my_spec, :main_agent_stood_down, [])
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

  defp via(project_id), do: {:via, Registry, {@registry, project_id}}

  @impl true
  def init(%Scope{} = scope) do
    {:ok, schedule(%{scope: scope})}
  end

  @impl true
  def handle_info(:check_in, state) do
    MainAgent.check_in(state.scope)
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

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
    case Application.get_env(:code_my_spec, :main_agent_digest_source) do
      :unavailable ->
        Digest.failed("the analyzer ledger did not answer")

      _ ->
        %Digest{
          work: MainAgent.list_agent_work(scope),
          machinery: MainAgent.check_machinery(scope),
          questions: MainAgent.list_open_questions(scope)
        }
    end
  end
end
