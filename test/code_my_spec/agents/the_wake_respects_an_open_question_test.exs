defmodule CodeMySpec.Agents.TheWakeRespectsAnOpenQuestionTest do
  @moduledoc """
  `wake/2` is fanned out by `Agents.wake_project_roles/2` to every continuous,
  running agent on any project-wide graph change — not this agent's own turn
  ending, somebody else's, anywhere in the project. `decide_with_key/3` already
  refuses to hammer an agent that asked a question or tapped out; `wake/2` had
  no such check at all, so an agent with either open was told "Work of your
  kind is available" on every unrelated change, sometimes under a minute apart
  on a project several worktrees edit at once, and had to spend a turn saying
  "still waiting" each time.

  The conversation John pointed at
  (`f3175e67-045c-4085-ac6f-da8abfd56d6a`) had a tap-out request outstanding
  and was woken by it repeatedly, both before and after the decision landed —
  the "after" half being the separate bug `Notifications.awaiting_answer?/1`
  only ever checking `QuestionRequest`, tested in
  `a_tap_out_decision_reaches_the_agent_test.exs`.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        working_copy: "/tmp/wake-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    # So the menu has something to say. Silence would otherwise prove nothing
    # about the guard — only that there was no work to wake the agent for,
    # which `Menu.render/2` already handles on its own.
    problem_fixture(scope, %{severity: :error, source: "compiler"})

    %{scope: scope, agent: agent}
  end

  test "an agent with a question open is not woken", %{scope: scope, agent: agent} do
    {:ok, _request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "title" => "Claude has a message",
        "questions" => [
          %{"question" => "Well?", "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    StopDecision.wake(scope, agent)

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "an agent with a tap-out request open is not woken", %{scope: scope, agent: agent} do
    {:ok, _request} =
      Notifications.create_permission_request(scope.user.id, %{
        "agent_id" => agent.id,
        "tool_name" => "tap_out",
        "tool_input" => %{"agent_id" => agent.id}
      })

    StopDecision.wake(scope, agent)

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "an agent holding neither is woken", %{scope: scope, agent: agent} do
    StopDecision.wake(scope, agent)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "Work of your kind is available"
  end
end
