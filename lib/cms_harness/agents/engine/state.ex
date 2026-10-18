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
end
