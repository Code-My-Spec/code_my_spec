defmodule CodeMySpec.Agents.ADiscardedTurnDoesNotStrandItsAgentTest do
  @moduledoc """
  An agent whose turn was thrown away gets another one, rather than sitting on
  a task nothing can wake it from.

  `Work.runnable_state?/1` refuses an agent holding an active task. That is
  right while a turn is running and wrong the moment one is not — and a turn
  discarded mid-flight leaves exactly that state: `turn_started_at` cleared,
  the task still held. Every recovery path then skips it, including the
  reconnect sweep that exists to catch what a restart broke.

  Measured 2026-09-22, and it is the intervention that recurred all session. A
  QA agent part-way through a browser re-test was discarded by an unrelated
  session's promote at 19:02:12, was told "you have an open task", and then sat
  untouched until it was messaged by hand six minutes later. On another project
  the same shape held a coding agent for eight days. On this machine `:4000`
  booted three times in 32 minutes, so any turn longer than a few minutes is
  likely to meet one.

  Holding a task is not evidence of a live turn. `turn_started_at` is, and this
  requires it to be nil before offering anything — an agent genuinely mid-turn
  is still left alone, which is what the guard was for.
  """
  use CodeMySpecSpex.Case, async: false

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
      AgentsRepository.update_agent(scope, held, %{
        turn_started_at: turn_started_at,
        work_request_id: nil,
        work_requested_at: nil
      })

    assert not is_nil(Agent.active_task(held)), "the premise is an agent holding a task"
    held
  end

  # Reaching `reserve/1` stamps a ref, and the dispatch that follows is what
  # this is really asking about. Observed on the row rather than the return
  # value for the same reason the stranded-reservation test does it.
  defp offered_a_turn?(agent_id) do
    not is_nil(Repo.get(Agent, agent_id).work_request_id) or
      Repo.get(Agent, agent_id).work_requested_at != nil
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

  test "a held task with no turn open is offered one", ctx do
    held = holding_a_task(ctx.scope, ctx.agent, nil)

    :ok = Work.resume_held_tasks(ctx.scope, held.working_copy_id)

    resumed = Enum.any?(drain(), &String.contains?(&1, "harness restarted"))

    assert resumed,
           """
           An agent holding a task with no turn open was left alone.

           That is not a busy agent, it is a stranded one: a discarded turn
           clears `turn_started_at` and leaves the task held, and every
           admission path refuses an agent holding a task. Nothing else is
           coming — measured at six minutes on one project and eight days on
           another, each ended by a human sending a message.
           """
  end

  test "an agent coming up does not resume another task-holder on its copy", ctx do
    held = holding_a_task(ctx.scope, ctx.agent, nil)

    {:ok, newcomer} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: false,
        status: :running,
        working_copy: held.working_copy,
        working_copy_id: held.working_copy_id
      })

    AgentPresence.present(newcomer)
    :ok = CodeMySpec.Agents.came_up(ctx.scope, newcomer.id)

    refute offered_a_turn?(held.id)
    held_id = held.id
    refute_received {:work_turn_requested, ^held_id, _, _}

    :ok = CodeMySpec.Agents.came_up(ctx.scope, held.id)
    assert_receive {:work_turn_requested, ^held_id, _, message}
    assert message =~ Agent.active_task(held).id
  end

  test "an agent genuinely mid-turn is left alone", ctx do
    held = holding_a_task(ctx.scope, ctx.agent, DateTime.utc_now())

    :ok = Work.resume_held_tasks(ctx.scope, held.working_copy_id)

    refute offered_a_turn?(held.id),
           """
           An agent with a turn open was handed a second one.

           `turn_started_at` is the mid-turn signal and the whole reason the
           active-task guard exists; resuming on the strength of a held task
           alone would interrupt exactly the work it is meant to protect.
           """
  end

  test "an agent holding nothing is not resumed", ctx do
    :ok = Work.resume_held_tasks(ctx.scope, ctx.agent.working_copy_id)

    refute Enum.any?(drain(), &String.contains?(&1, "harness restarted")),
           "an agent with no task was told its turn had been discarded"
  end
end
