defmodule CodeMySpec.Agents.ATurnEndInsideTheChannelStillAsksForWorkTest do
  @moduledoc """
  104bcb23: `StopDecision.deliver/3` runs inside the harness channel at turn end,
  and its turn request is a call back into that channel. The transport refuses
  a call to itself, so a continuous agent that finished a task sat idle with
  work waiting — 79 refusals in one day.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Transport.Harness
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, Harness)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/turn-end-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    Map.put(ctx, :agent, agent)
  end

  test "the channel that ran the turn is asked for the next one", ctx do
    # This test process is the channel: it holds the working copy.
    :ok = HarnessRegistry.register_executor(ctx.scope.active_working_copy_id)

    :ok = StopDecision.deliver(ctx.scope, ctx.agent)

    assert_receive {:"$gen_call", _from, {:request_work_turn, %{"agent_id" => agent_id}}},
                   2_000,
                   "the turn request never reached the channel — refused as a call to itself"

    assert agent_id == ctx.agent.id
  end
end
