defmodule CmsHarness.Agents.Engine.State do
  @moduledoc """
  Pure queue transitions for one harness agent.

  `Engine` supplies process ownership and runs Alloy. This module answers only
  how incoming work changes the active-turn and queued-work state.
  """

  @type entry :: %{ref: String.t(), message: String.t(), timeout: timeout()}
  @type state :: %{required(:turn) => map() | nil, required(:queue) => [entry()]}

  @spec offer(state(), entry()) :: {:start, entry(), state()} | {:queued, state()}
  def offer(%{turn: nil} = state, entry), do: {:start, entry, state}
  def offer(state, entry), do: {:queued, %{state | queue: state.queue ++ [entry]}}

  @spec finish(state()) :: {:idle, state()} | {:start, entry(), state()}
  def finish(%{queue: []} = state), do: {:idle, %{state | turn: nil}}

  def finish(%{queue: [next | rest]} = state),
    do: {:start, next, %{state | turn: nil, queue: rest}}

  @spec withdraw(state(), String.t()) :: {:ok, state()} | :already_delivered
  def withdraw(state, ref) do
    case Enum.split_with(state.queue, &(&1.ref == ref)) do
      {[], _keep} -> :already_delivered
      {_taken, keep} -> {:ok, %{state | queue: keep}}
    end
  end

  @spec status(state()) :: %{busy?: boolean(), queued: non_neg_integer()}
  def status(state), do: %{busy?: state.turn != nil, queued: length(state.queue)}

  def whereis(agent_id) do
    case Registry.lookup(CmsHarness.Registry, {:agent, agent_id}) do
      [{pid, _}] -> if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running})
      _ -> {:error, :not_running}
    end
  end

  def running do
    CmsHarness.Registry
    |> Registry.select([{{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {id, _pid} -> id end)
  end
end
