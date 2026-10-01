defmodule CodeMySpec.Agents.RefusalWake do
  @moduledoc """
  Runs an agent's held turn-end delivery at the retry time its provider named.

  `Waiting` holds the turn end of an agent the provider refused until later;
  nothing else wakes one holding a task once that time passes. So the retry
  time is the wake.

  One timer per agent, in memory like `MainAgent.Cadence`'s, re-armed on a
  harness reconnect (`rearm/2`). A later refusal replaces the timer. The wake
  re-reads the agent and does nothing unless that same refusal still stands
  and no turn is open — a turn that succeeded meanwhile cleared it.
  """

  use GenServer

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Users.Scope

  # `Process.send_after/3`'s ceiling; a later time is reached in hops.
  @max_delay_ms 4_294_967_295

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Wake `agent_id` at `retry_at`, replacing any wake it already has."
  @spec schedule(Scope.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def schedule(%Scope{} = scope, agent_id, %DateTime{} = retry_at),
    do: GenServer.cast(__MODULE__, {:schedule, scope, agent_id, retry_at})

  @doc """
  Re-arm the wakes a restart dropped, for this copy's agents still refused
  until later. One whose time already passed is the reconnect sweep's.
  """
  @spec rearm(Scope.t(), Ecto.UUID.t()) :: :ok
  def rearm(%Scope{} = scope, copy_id) do
    now = DateTime.utc_now()

    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and later?(&1.provider_retry_at, now)))
    |> Enum.each(&schedule(scope, &1.id, &1.provider_retry_at))
  end

  defp later?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :gt
  defp later?(_at, _now), do: false

  @impl true
  def init(timers), do: {:ok, timers}

  @impl true
  def handle_cast({:schedule, scope, agent_id, retry_at}, timers) do
    with {ref, _at} <- timers[agent_id], do: Process.cancel_timer(ref)

    ref = Process.send_after(self(), {:wake, scope, agent_id, retry_at}, delay_ms(retry_at))
    {:noreply, Map.put(timers, agent_id, {ref, retry_at})}
  end

  @impl true
  def handle_info({:wake, scope, agent_id, retry_at}, timers) do
    timers =
      case timers[agent_id] do
        {_ref, ^retry_at} -> Map.delete(timers, agent_id)
        _replaced -> timers
      end

    # Off this process: the delivery runs validation and dispatches.
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      wake(scope, agent_id, retry_at)
    end)

    {:noreply, timers}
  end

  @doc "Deliver the held turn end if this refusal still stands and its time has come."
  def wake(scope, agent_id, retry_at) do
    case due(scope, agent_id, retry_at) do
      {:due, agent} -> StopDecision.deliver(scope, agent, [])
      {:later, at} -> schedule(scope, agent_id, at)
      :moved_on -> :ok
    end
  end

  @doc """
  Whether a wake for `retry_at` should act: `{:due, agent}` once that refusal's
  time has come, `{:later, at}` before it, `:moved_on` when a later refusal or a
  successful turn replaced it, or a turn is open.
  """
  def due(scope, agent_id, retry_at) do
    with {:ok, %Agent{provider_retry_at: %DateTime{} = at, turn_started_at: nil} = agent} <-
           AgentsRepository.fetch_agent(scope, agent_id),
         :eq <- DateTime.compare(at, retry_at) do
      if later?(at, DateTime.utc_now()), do: {:later, at}, else: {:due, agent}
    else
      _moved_on -> :moved_on
    end
  end

  # Rounded up: a timer a microsecond early finds the refusal still standing.
  defp delay_ms(retry_at) do
    micros = DateTime.diff(retry_at, DateTime.utc_now(), :microsecond)
    div(micros + 999, 1000) |> max(0) |> min(@max_delay_ms)
  end
end
