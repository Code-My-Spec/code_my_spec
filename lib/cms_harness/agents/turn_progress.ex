defmodule CmsHarness.Agents.TurnProgress do
  @moduledoc """
  Hands the engine the agent's transcript after each round of tool calls, so a
  turn stopped part-way keeps what it did.

  The engine cannot ask Alloy mid-turn — Alloy is the one running the turn —
  and its own checkpoint is the turn's start. Stopping a turn from there threw
  away every call the turn had made, which is what a message sent now does to
  a busy agent (story 1051): the turn is stopped, and the agent carries on from
  its last completed step with the message in front of it.

  Reported through `config.context[:on_progress]`, because middleware is a
  module and what it reports to is per-agent. No reporter changes nothing.
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    case state.config.context[:on_progress] do
      report when is_function(report, 1) -> report.(State.messages(state))
      _none -> :ok
    end

    state
  end

  def call(_hook, %State{} = state), do: state
end
