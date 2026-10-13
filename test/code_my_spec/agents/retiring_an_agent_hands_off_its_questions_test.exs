defmodule CodeMySpec.Agents.RetiringAnAgentHandsOffItsQuestionsTest do
  @moduledoc """
  Retiring an agent orphaned its open questions: the answer was delivered to an
  agent that would never read it (metric_flow's customer question 5a7fdcce on a
  product being moved to the main copy). They go to its successor in the role,
  else to main, with their text, history and holder unchanged.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    {:ok, main_copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, _} = WorkingCopies.designate_main(scope, main_copy.id)
    feature = scope.active_working_copy_id
    old = agent(scope, :product, feature)
    request = ask(scope, old)
    %{scope: scope, main_copy: main_copy, old: old, request: request}
  end

  defp agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        working_copy: "/tmp/handoff-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp ask(scope, agent) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Refund window",
          "holder" => "user",
          "questions" => [%{"question" => "14 or 30 days?", "options" => []}]
        },
        nil
      )

    request
  end

  defp owner(request), do: Notifications.get_question_request(request.id)

  test "goes to the product on the main copy, unchanged otherwise", ctx do
    successor = agent(ctx.scope, :product, ctx.main_copy.id)

    {:ok, _} = Agents.retire_agent(ctx.scope, ctx.old.id, reason: "moved to main")

    moved = owner(ctx.request)
    assert moved.agent_id == successor.id
    assert moved.status == "pending"
    assert moved.holder == ctx.request.holder
    assert moved.questions == ctx.request.questions
  end

  test "with no other product, goes to main", ctx do
    main = agent(%{ctx.scope | active_working_copy_id: ctx.main_copy.id}, :main, ctx.main_copy.id)

    {:ok, _} = Agents.retire_agent(ctx.scope, ctx.old.id)

    assert owner(ctx.request).agent_id == main.id
  end

  test "an answered question stays with the agent that asked it", ctx do
    successor = agent(ctx.scope, :product, ctx.main_copy.id)
    {:ok, _} = Notifications.answer_question_request(ctx.request.id, %{"14 or 30 days?" => "30"})

    {:ok, _} = Agents.retire_agent(ctx.scope, ctx.old.id)

    refute owner(ctx.request).agent_id == successor.id
  end
end
