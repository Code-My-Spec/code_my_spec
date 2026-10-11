defmodule CmsHarness.Agents.Engine.State do
  @moduledoc """
  Pure active-turn transitions for one harness agent.

  `Engine` supplies process ownership and runs Alloy. This module answers only
  whether an idle engine can start work. Waiting messages belong to the server mailbox.
  """

  @type entry :: %{ref: String.t(), message: String.t(), timeout: timeout()}
  @type state :: %{required(:turn) => map() | nil}

  @doc "Admit a work request only when idle; retain admitted IDs against transport replays."
  def offer_work(state, entry) do
    admitted = Map.get(state, :admitted_work_requests, MapSet.new())

    cond do
      MapSet.member?(admitted, entry.ref) ->
        {:rejected, :duplicate, state}

      state.turn != nil ->
        {:rejected, :busy, state}

      true ->
        {:start, entry, Map.put(state, :admitted_work_requests, MapSet.put(admitted, entry.ref))}
    end
  end

  @spec finish(state()) :: {:idle, state()}
  def finish(state), do: {:idle, %{state | turn: nil}}

  @spec status(state()) :: %{busy?: boolean()}
  def status(state), do: %{busy?: state.turn != nil}

  def whereis(agent_id) do
    case Registry.lookup(CmsHarness.Registry, {:agent, agent_id}) do
      [{pid, _}] -> if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running})
      _ -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  def running do
    CmsHarness.Registry
    |> Registry.select([{{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {id, _pid} -> id end)
  rescue
    ArgumentError -> []
  end
end
