defmodule CodeMySpec.Agents.AnOffAgentsQuestionsGoToItsSuccessorTest do
  @moduledoc """
  Retiring an agent hands its pending questions to its successor
  (`retiring_an_agent_hands_off_its_questions_test.exs`), but an agent that is
  merely off -- stopped, not retired, free to be restarted on its own seat --
  was never revisited: nothing else ever looks at an off agent's row again to
  notice it is never answering. A same-role successor starting anywhere on the
  project is the first thing that could read the question, so starting one
  hands off every off same-role agent's pending questions the same way
  retiring does.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, feature} =
      WorkingCopies.issue(scope, nil, label: "a feature copy", device: device_fixture(scope))

    feature = with_root(feature, "feature")

    {:ok, main_copy} =
      WorkingCopies.issue(scope, nil, label: "the main copy", device: device_fixture(scope))

    main_copy = with_root(main_copy, "main")
    {:ok, _} = WorkingCopies.designate_main(scope, main_copy.id)

    %{scope: scope, feature: feature, main_copy: main_copy}
  end

  # `put_destination/2` derives `working_copy` from the copy's own root and
  # overwrites whatever the caller passed, so every copy a start names needs
  # one or every start fails validation on a field the caller did supply.
  defp with_root(copy, label) do
    copy
    |> Ecto.Changeset.change(root: "/workspace/off-handoff-#{label}-#{System.unique_integer([:positive])}")
    |> CodeMySpec.Repo.update!()
  end

  defp off_agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :stopped,
        working_copy: "/tmp/off-handoff-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id
      })

    {:ok, off} = AgentsRepository.update_agent(scope, agent, %{off_at: DateTime.utc_now()})
    off
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

  defp start(scope, role, copy_id) do
    {:ok, agent} =
      Agents.start_agent(scope, %{
        role: to_string(role),
        provider: "anthropic",
        working_copy_id: copy_id
      })

    agent
  end

  test "a same-role successor starting picks up an off agent's pending question", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    successor = start(ctx.scope, :product, ctx.main_copy.id)

    moved = owner(request)
    assert moved.agent_id == successor.id
    assert moved.status == "pending"
    assert moved.holder == request.holder
    assert moved.questions == request.questions
  end

  test "an answered question stays with the agent that asked it", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)
    {:ok, _} = Notifications.answer_question_request(request.id, %{"14 or 30 days?" => "30"})

    successor = start(ctx.scope, :product, ctx.main_copy.id)

    refute owner(request).agent_id == successor.id
  end

  test "a different role starting does not pick up the question", ctx do
    old = off_agent(ctx.scope, :product, ctx.feature.id)
    request = ask(ctx.scope, old)

    _coder = start(ctx.scope, :coding, ctx.feature.id)

    assert owner(request).agent_id == old.id
  end
end
