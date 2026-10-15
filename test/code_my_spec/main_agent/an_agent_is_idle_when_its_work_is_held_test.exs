defmodule CodeMySpec.Agents.Main.AnAgentIsIdleWhenItsWorkIsHeldTest do
  @moduledoc """
  The main agent's "this agent has work" is what that agent would be offered.

  Issue 4849f20b. `WorkRepository` asked the graph whether a queue held work
  and stopped there, while `Work` — the thing that actually offers a turn — also
  drops every node another agent on the copy already holds, and `start_task`
  refuses to claim one (`:task_owned_by_another_agent`). An agent whose only
  work was in a neighbour's hands was reported STALLED and the main agent was
  told to nudge it, for a turn that would never be offered.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  # One step short of `bdd_specs_passing`: a named coding node on the board, so
  # "not idle" in the premise is real work rather than an empty graph.
  setup ctx do
    RecordingAgentTransport.listen(ctx)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    %{idle: coding_agent(ctx.scope), holder: coding_agent(ctx.scope)}
  end

  defp coding_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/held-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp entry(scope, agent),
    do: Enum.find(MainAgent.list_agent_work(scope), &(&1.agent_id == agent.id))

  # Active on the holder, as `start_task` leaves a claim.
  defp claim(scope, holder, node) do
    ref = %{"story" => :story_id, "component" => :component_id, "project" => :project_id}

    {:ok, _} =
      TaskOwner.add_task(scope, holder, %{
        :requirement_name => node.name,
        :status => :active,
        Map.fetch!(ref, node.entity_type) => node.entity_id
      })
  end

  test "an agent whose only work another agent holds is idle, as Work says", ctx do
    assert [node] = Requirements.actionable_for_role(ctx.scope, :coding)
    refute entry(ctx.scope, ctx.idle).idle?, "premise: unheld work reads as work"

    claim(ctx.scope, ctx.holder, node)

    assert {:ok, :not_runnable} = Work.request_turn_if_runnable(ctx.scope, ctx.idle, :test)

    assert entry(ctx.scope, ctx.idle).idle?,
           "the main agent was told this agent has work that it would never be offered"
  end
end
