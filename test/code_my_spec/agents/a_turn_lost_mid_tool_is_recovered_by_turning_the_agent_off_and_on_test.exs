defmodule CodeMySpec.Agents.ATurnLostMidToolIsRecoveredByTurningTheAgentOffAndOnTest do
  @moduledoc """
  fef62356. An agent whose turn ended without its tool result (the engine or
  its port gone, a harness restart) holds an active task with `turn_started_at`
  still set and nothing in flight. The ordinary offer path refuses it (it
  holds a task) and the stranded-task sweep skips it (a turn "is open"), so
  nothing wakes it. Turning it off and on again is the floor: it must end up
  offered one turn to resume or cancel the task.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    RecordingAgentTransport.listen(ctx)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/stranded-turn-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  # `tasks` is an embed written through `Agent.add_task/2`, not a castable
  # attribute — passing it to `update_agent/3` drops it silently, which is how
  # an earlier version of this test asserted against an agent holding nothing.
  defp holding_a_task(scope, agent, turn_started_at) do
    {:ok, held} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "bdd_specs_passing",
        started_at: DateTime.add(DateTime.utc_now(), -300, :second)
      })
      |> Repo.update()

    {:ok, held} =
      AgentsRepository.update_agent(scope, held, %{turn_started_at: turn_started_at})

    assert not is_nil(Agent.active_task(held)), "the premise is an agent holding a task"
    held
  end

  # `request_work_turn/5` is the path a resume takes, and `RecordingAgentTransport`
  # reports it as `:work_turn_requested` — not the `:agent_dispatch` a plain
  # message produces. Matching only the latter is how an earlier version of this
  # test read a working resume as silence.
  defp drain(acc \\ []) do
    receive do
      {:work_turn_requested, _id, _ref, message} -> drain([message | acc])
      {:agent_dispatch, _id, _ref, message} -> drain([message | acc])
      {:agent_message, _id, message} -> drain([message | acc])
    after
      300 -> acc
    end
  end

  test "turning an agent with a lost turn off and on offers it a turn to resume its task", ctx do
    # The turn started and its result never came: `turn_started_at` set long ago.
    stale = DateTime.add(DateTime.utc_now(), -2_400, :second)
    held = holding_a_task(ctx.scope, ctx.agent, stale)

    # The premise: the sweep alone leaves it, a turn being "open".
    :ok = Work.resume_held_tasks(ctx.scope, held.working_copy_id)
    assert drain() == [], "the premise: nothing is offered while the turn reads as open"

    {:ok, _off} = CodeMySpec.Agents.turn_off_agent(ctx.scope, held.id)
    AgentPresence.present(Repo.reload!(held))
    {:ok, _on} = CodeMySpec.Agents.turn_on_agent(ctx.scope, held.id)
    AgentPresence.present(Repo.reload!(held))
    :ok = CodeMySpec.Agents.came_up(ctx.scope, held.id)

    assert Enum.any?(drain(), &String.contains?(&1, "harness restarted")),
           "turn_off plus turn_on left an agent with a lost turn and a held task unwoken"
  end
end
