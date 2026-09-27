defmodule CodeMySpec.Agents.ATappedOutAgentIsNotNudgedTest do
  @moduledoc """
  An agent that tapped out has asked to leave the loop until a person answers.

  metric_flow's coding agent, 2026-09-27: its only task blocked on a tap-out,
  and the work loop offered it a turn 42 times over 5.5 hours. Each turn it
  called get_next_requirement, was shown the blocked task, could not start it,
  and said so again.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/tapped-out-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  defp tapped_out(agent, resolved_at) do
    agent
    |> Agent.add_task(%{
      status: :blocked,
      requirement_name: "bdd_specs_exist",
      blocker_type: :tap_out,
      blocker_id: Ecto.UUID.generate(),
      blocked_at: DateTime.utc_now(),
      blocker_resolved_at: resolved_at
    })
    |> Repo.update!()
  end

  test "is not offered a turn while its tap-out waits", %{scope: scope, agent: agent} do
    agent = tapped_out(agent, nil)

    assert {:ok, :not_runnable} = Work.request_turn_if_runnable(scope, agent, :test)
  end

  test "is offered one again once the tap-out is answered", %{scope: scope, agent: agent} do
    agent = tapped_out(agent, DateTime.utc_now())

    refute match?({:ok, :not_runnable}, Work.request_turn_if_runnable(scope, agent, :test)),
           "a resolved blocker must not keep the agent out of the loop"
  end
end
