defmodule CodeMySpec.Agents.AReleasedTaskIsWorkEvenWhenItsNodeIsGoneTest do
  @moduledoc """
  b9f21a0e. A coder tapped out of a task whose component had been made stale by a
  product decision; the tap-out was denied. The task stayed blocked with its
  blocker resolved, and the agent was never given a turn: with no graph work, a
  released task whose node the graph no longer offers was not work at all, so
  idle admission and `set_agent_continuous` found "nothing to do ... holding an
  undispositioned task". Only re-selecting the story, which cancelled the task,
  freed it.

  Story 704, criteria 1479 and 1484: the criteria stand. Denying does not
  unblock the task; the agent is admitted exactly one turn in which to read the
  decision and either resume the task or cancel it.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Everything satisfied: the graph holds no work for coding, so the only thing
  # the agent can be offered is the task it holds.
  setup ctx do
    RecordingAgentTransport.listen(ctx)
    ctx = FullSatisfactionFixtures.apply(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/released-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  defp hold_released_task(agent) do
    agent
    |> Agent.add_task(%{
      status: :blocked,
      requirement_name: "implementation_file",
      component_id: Ecto.UUID.generate(),
      blocker_type: :tap_out,
      blocker_id: Ecto.UUID.generate(),
      blocker_resolved_at: DateTime.utc_now(),
      started_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  test "the premise: the graph holds no work for the agent", ctx do
    assert Work.claimable_work(ctx.scope, ctx.agent) == []
  end

  test "an idle agent holding a released task whose node is gone is admitted a turn", ctx do
    agent = hold_released_task(ctx.agent)
    agent_id = agent.id

    assert {:ok, ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)
    assert is_binary(ref)
    assert_receive {:work_turn_requested, ^agent_id, ^ref, prompt}, 2_000
    assert prompt =~ "was denied; resume task"

    assert prompt =~ "cancel_task",
           "the holder is not told how to dispose of work the graph no longer offers"
  end

  test "and a second request while that turn is open admits no second turn", ctx do
    agent = hold_released_task(ctx.agent)
    {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)
    fresh = Repo.get!(Agent, agent.id)

    refute match?(
             {:ok, ref} when is_binary(ref),
             Work.request_turn_if_runnable(ctx.scope, fresh, :test)
           )
  end

  test "denying the tap-out marks the blocker resolved and the agent gets exactly one turn",
       ctx do
    agent =
      ctx.agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "implementation_file",
        component_id: Ecto.UUID.generate(),
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

    [task] = agent.tasks
    agent_id = agent.id

    {:ok, request} =
      CodeMySpec.Notifications.request_agent_tap_out(ctx.scope, agent_id, task.id, "stale")

    {:ok, _} = CodeMySpec.Notifications.resolve_permission_request(request.id, "deny")

    assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000
    assert prompt =~ "was denied"

    assert %{status: :blocked, blocker_resolved_at: %DateTime{}} =
             Agent.find_task(Repo.get!(Agent, agent_id), task.id)

    # A repeated decision is refused, and admits no second turn.
    assert {:error, {:already_resolved, _}} =
             CodeMySpec.Notifications.resolve_permission_request(request.id, "deny")

    refute_receive {:work_turn_requested, ^agent_id, _ref, _prompt}, 500
  end
end
