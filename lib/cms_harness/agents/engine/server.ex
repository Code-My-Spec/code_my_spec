defmodule CmsHarness.Agents.Engine.Server do
  @moduledoc false

  use GenServer, restart: :temporary

  alias CmsHarness.Agents.Engine.Impl
  alias CmsHarness.Agents.Engine.State

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {CmsHarness.Registry, {:agent, agent_id}}}
    )
  end

  @impl true
  def init(opts) do
    case Impl.init(opts) do
      {:ok, state} ->
        send(self(), :mailbox_ready)
        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  def handle_call({:send, ref, message, timeout, await?}, from, %{turn: nil} = state) do
    case Impl.consume_message(state, ref) do
      :ok ->
        awaiting = if await?, do: from
        state = %{state | turn: Impl.start_turn(state, ref, message, timeout, awaiting)}
        if await?, do: {:noreply, state}, else: {:reply, {:ok, :started}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:send, _ref, _message, _timeout, _await?}, _from, state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:work_available, ref, message, timeout}, _from, state) do
    case State.offer_work(state, %{ref: ref, message: message, timeout: timeout}) do
      {:start, entry, state} ->
        {:reply, {:ok, :started},
         %{state | turn: Impl.start_turn(state, entry.ref, entry.message, entry.timeout, nil)}}

      {:rejected, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:alloy, _from, state) do
    {:reply, {:ok, state.alloy}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, {:ok, State.status(state)}, state}
  end

  def handle_call(:tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:mcp_client, _from, state) do
    {:reply, state.mcp_client, state}
  end

  @impl true
  def handle_info(:mailbox_ready, state) do
    case state.on_event do
      fun when is_function(fun, 2) ->
        fun.(state.agent_id, %{
          event: :mailbox_ready,
          generation: state.generation,
          ref: state.turn && state.turn.ref
        })

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({task_ref, result}, %{turn: %{task: %Task{ref: task_ref}}} = state) do
    Process.demonitor(task_ref, [:flush])
    Impl.settle(state, result)
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{turn: %{task: %Task{ref: task_ref}}} = state
      ) do
    Impl.abort_turn(state, {:turn_waiter_failed, reason})
  end

  def handle_info({:turn_ceiling, task_ref}, %{turn: %{task: %Task{ref: task_ref}}} = state) do
    Impl.abort_turn(state, :turn_ceiling_exceeded)
  end

  # Cancelled timers and completed tasks can already have messages in transit.
  def handle_info({:turn_ceiling, _ref}, state), do: {:noreply, state}
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, alloy, reason}, %{alloy: alloy} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state), do: Impl.terminate(reason, state)
end
