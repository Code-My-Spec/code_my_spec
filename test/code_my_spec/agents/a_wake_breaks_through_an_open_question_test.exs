defmodule CodeMySpec.Agents.AWakeBreaksThroughAnOpenQuestionTest do
  @moduledoc """
  `wake/2` is fanned out by `Agents.wake_project_roles/2` to every continuous,
  running agent on any project-wide graph change — not this agent's own turn
  ending, somebody else's, anywhere in the project.

  This file used to assert the opposite of what is tested here: an earlier
  fix (`63c43862b`) gated `wake/2` on `Notifications.awaiting_answer?/1`, the
  same guard `decide_with_key/3` uses to stay quiet for an agent that just
  asked a question. That looked like the same rule and was not. A stop
  decision is answering "what now" at the end of a turn an idle agent already
  finished; a wake is the only thing that starts an idle agent back up. Gating
  it on `awaiting_answer?` did not make an agent quieter, it removed it from
  the fleet — one unanswered question, or a `tap_out` nobody had decided, and
  the graph could never reach it again. `880c7713` sat idle seven hours that
  way, holding 17 actionable requirements, while every surface reported it
  running and available.

  `00ebc7d43` corrected it: only `working?` gates a wake now. See
  `CodeMySpec.Agents.StopDecision`'s moduledoc, "A wake breaks through a
  pending question; a stop decision does not", for the full reasoning.
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

  test "an agent with a question open is still woken", %{scope: scope, agent: agent} do
    {:ok, _request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "title" => "Claude has a message",
        "questions" => [
          %{"question" => "Well?", "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    StopDecision.wake(scope, agent)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "Work of your kind is available"
  end

  test "an agent with a tap-out request open is still woken", %{scope: scope, agent: agent} do
    {:ok, _request} =
      Notifications.create_permission_request(scope.user.id, %{
        "agent_id" => agent.id,
        "tool_name" => "tap_out",
        "tool_input" => %{"agent_id" => agent.id}
      })

    StopDecision.wake(scope, agent)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "Work of your kind is available"
  end

  test "an agent holding neither is woken", %{scope: scope, agent: agent} do
    StopDecision.wake(scope, agent)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == agent.id
    assert message =~ "Work of your kind is available"
  end
end
