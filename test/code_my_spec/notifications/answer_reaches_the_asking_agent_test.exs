defmodule CodeMySpec.Notifications.AnswerReachesTheAskingAgentTest do
  @moduledoc """
  The other half of `ask_user` for an agent we run.

  `check_answer` polls, which suits a Claude Code session that keeps running
  regardless. It cannot suit an agent that stops: a stopped agent has nothing to
  poll with, and holding one open to poll spends a turn per check on a person
  who has not started typing.

  So an agent that asks is allowed to stop, and the answer is dispatched to it
  when it lands. Both halves are tested here, because either one alone is a
  silent hang — allowed to stop with no delivery is an agent that never wakes,
  and delivery without the allowance is the hammering it was meant to end.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    # A real copy: `working_copy_id` is a foreign key, so an invented one is
    # refused before any of this is reached.
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        working_copy: "/tmp/answers-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  defp ask(scope, agent, question) do
    {:ok, request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "title" => "Claude has a message",
        "questions" => [
          %{"question" => question, "header" => nil, "multiSelect" => false, "options" => []}
        ]
      })

    request
  end

  describe "when the answer lands" do
    test "it is dispatched to the agent that asked", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Are open borders bilateral?")

      {:ok, _answered} =
        Notifications.answer_question_request(request.id, %{
          "Are open borders bilateral?" => "Yes, and either side can revoke"
        })

      assert_receive {:agent_message, id, message}
      assert id == agent.id
      assert message =~ "The user answered your question"
      assert message =~ "Are open borders bilateral?"
      assert message =~ "Yes, and either side can revoke"
    end

    # The agent asked, stopped, and is being woken by this — so the question has
    # to come back with the answer, or it is reading a reply to something it
    # cannot see.
    test "the message carries the question, not just the answer", %{scope: s, agent: agent} do
      request = ask(s, agent, "Which city falls first?")

      {:ok, _} =
        Notifications.answer_question_request(request.id, %{"Which city falls first?" => "Ravena"})

      assert_receive {:agent_message, _id, message}
      assert message =~ "Q: Which city falls first?"
      assert message =~ "A: Ravena"
    end

    # A Claude Code session has no process of ours to message and polls with
    # `check_answer`. Dispatching for it would be a message to nobody.
    test "a question with no agent dispatches nothing", %{scope: scope} do
      {:ok, request} =
        Notifications.create_question_request(scope.user.id, %{
          "title" => "Claude has a message",
          "questions" => [
            %{"question" => "Anyone?", "header" => nil, "multiSelect" => false, "options" => []}
          ]
        })

      {:ok, _} = Notifications.answer_question_request(request.id, %{"Anyone?" => "no"})

      refute_receive {:agent_message, _id, _message}, 100
    end
  end

  describe "while the question is outstanding" do
    test "the agent is reported as waiting", %{scope: scope, agent: agent} do
      refute Notifications.awaiting_answer?(agent.id)

      ask(scope, agent, "Well?")

      assert Notifications.awaiting_answer?(agent.id)
    end

    test "answering clears it", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Well?")
      {:ok, _} = Notifications.answer_question_request(request.id, %{"Well?" => "fine"})

      refute Notifications.awaiting_answer?(agent.id)
    end

    # The point of the whole change. An agent with an open task is normally
    # refused a stop — that is the task clause — and an agent waiting on a
    # person must be exempt, or it is hammered for as long as the person takes
    # to reply.
    test "it is allowed to stop even holding an open task", %{scope: scope, agent: agent} do
      {:ok, agent} =
        agent
        |> Agent.add_task(%{
          id: "held",
          status: :active,
          requirement_name: "three_amigos_complete",
          story_id: 994,
          started_at: ~U[2026-09-06 11:58:00.189607Z]
        })
        |> Repo.update()

      # The guard the rest of this test rests on. `Agent.changeset/2` silently
      # drops the embed, and without this the assertions below would be made
      # against an agent holding nothing.
      assert [%{status: :active}] = agent.tasks

      # Without a question, the open task refuses the stop.
      assert StopDecision.decide(scope, agent) =~ "open task"

      ask(scope, agent, "Are open borders bilateral?")

      assert StopDecision.decide(scope, agent) == nil
    end
  end

  describe "an agent that has gone away" do
    # The answer is the person's and is recorded either way. Failing their
    # submission because an agent's machine went missing would lose the answer
    # to save the notification.
    test "does not fail the person's answer", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Still there?")
      {:ok, _} = Repo.delete(agent)

      assert {:ok, answered} =
               Notifications.answer_question_request(request.id, %{"Still there?" => "yes"})

      assert answered.status == "answered"
    end
  end
end
