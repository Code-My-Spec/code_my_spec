defmodule CodeMySpec.Notifications.AnswerReachesTheAskingAgentTest do
  @moduledoc """
  The other half of `ask_user` for an agent we run.

  An agent that asks is allowed to stop, and what it comes back to is the
  *saved question* — its answer, who wrote it, and whether that answer replaced
  an earlier one. Nothing is pushed at it.

  It used to be pushed. `answer_question_request/3` dispatched the answer text
  the moment it was saved, which made the agent's machine busy and queued
  content for an agent that had asked to be left alone — exactly what the plan
  retiring `wake` lists under what goes ("task-control `send_to_agent`
  deliveries"). Criterion 3219 states the replacement as a claim: the
  originating agent reads both answers twice while its conversation stays
  byte-identical and its engine never takes a turn.

  So both halves are still tested here, and the second one has inverted. The
  answer has to be durable enough to read repeatedly — otherwise an agent that
  stopped never learns it — and answering must reach the agent's process not at
  all, otherwise "allowed to stop" is a fiction.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)

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

    AgentPresence.present(agent)

    # The conversation the answer must leave alone. An agent always has one in
    # production, opened when it starts, so "nothing was written into it" is
    # only a claim worth making against a conversation that exists.
    {:ok, conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    %{scope: scope, agent: agent, conversation: conversation}
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

  defp message_texts(conversation) do
    conversation
    |> CodeMySpec.Conversations.list_messages()
    |> Enum.flat_map(fn m -> Enum.map(m.content || [], &Map.get(&1, "text", "")) end)
  end

  describe "when the answer lands" do
    test "a repeated submission is refused, while an override replaces the text", ctx do
      request = ask(ctx.scope, ctx.agent, "Which option?")

      assert {:ok, _} =
               Notifications.answer_question_request(request.id, %{"Which option?" => "First"},
                 answered_by: "main_agent"
               )

      assert %{status: "answered", answered_by: "main_agent", overruled: false} =
               Notifications.get_question_request(request.id)

      assert {:error, {:already_resolved, "answered"}} =
               Notifications.answer_question_request(request.id, %{"Which option?" => "First"},
                 answered_by: "main_agent"
               )

      # The user is the one party allowed to answer a second time, because
      # theirs is the intent rather than a reading of the records.
      assert {:ok, _} =
               Notifications.answer_question_request(request.id, %{"Which option?" => "Second"})

      assert %{answers: answers, answered_by: "user", overruled: true} =
               Notifications.get_question_request(request.id)

      assert answers["Which option?"] == "Second"

      assert {:error, {:already_resolved, "answered"}} =
               Notifications.answer_question_request(request.id, %{"Which option?" => "Second"})
    end

    test "it is saved against the question the agent raised", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Are open borders bilateral?")

      {:ok, _answered} =
        Notifications.answer_question_request(request.id, %{
          "Are open borders bilateral?" => "Yes, and either side can revoke"
        })

      saved = Notifications.get_question_request(request.id)

      assert saved.agent_id == agent.id
      assert saved.answers["Are open borders bilateral?"] == "Yes, and either side can revoke"
    end

    # The agent asked and stopped, so the question has to still be on the record
    # beside the answer — otherwise it comes back to a reply to something it
    # cannot see.
    test "the saved question keeps its text beside the answer", %{scope: s, agent: agent} do
      request = ask(s, agent, "Which city falls first?")

      {:ok, _} =
        Notifications.answer_question_request(request.id, %{"Which city falls first?" => "Ravena"})

      saved = Notifications.get_question_request(request.id)

      assert Enum.any?(saved.questions, &(Map.get(&1, "question") == "Which city falls first?"))
      assert saved.answers["Which city falls first?"] == "Ravena"
    end

    # Reading it is not consuming it. An agent that stopped may come back to the
    # same question more than once — a second stop hook, a restarted machine —
    # and each read has to say the same thing.
    test "it can be read back more than once", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Well?")
      {:ok, _} = Notifications.answer_question_request(request.id, %{"Well?" => "fine"})

      for _ <- 1..2 do
        assert %{status: "answered", answers: %{"Well?" => "fine"}} =
                 Notifications.get_question_request(request.id)
      end
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

    # The point of the whole change, restated for task-scoped questions.
    #
    # An agent with an open task is normally refused a stop — that is the task
    # clause — and an agent waiting on a person must be exempt. It used to be
    # exempt globally: any unanswered question anywhere silenced the decision,
    # which is what took `880c7713` out of the fleet for seven hours holding 17
    # actionable requirements. Now the exemption is the blocker itself. Asking
    # against the active task blocks *that task*, so there is no active task
    # left to refuse the stop, and every other eligible thing stays available.
    test "a task-scoped question blocks its own task rather than the agent",
         %{scope: scope, agent: agent} do
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

      {:ok, _request} =
        Notifications.create_agent_question_request(scope, agent.id, %{
          "title" => "Claude has a message",
          "questions" => [
            %{
              "question" => "Are open borders bilateral?",
              "header" => nil,
              "multiSelect" => false,
              "options" => []
            }
          ]
        })

      blocked = Repo.get(Agent, agent.id)
      assert [%{status: :blocked, blocker_type: :question}] = blocked.tasks

      # `nil` is the strongest form of this: nothing to say at all. Either way
      # what must not happen is a directive demanding disposition of a task the
      # agent has already handed to a person.
      decision = StopDecision.decide(scope, blocked)

      refute decision && decision =~ "open task",
             "the question blocked the task, so nothing active remains to refuse the stop"
    end
  end

  # The failure John hit, and then the second thought about it.
  #
  # `message_agent/4` is a `GenServer.call` to the process holding the working
  # copy, and that process runs the whole turn inside the call — so delivering
  # that way waited out the agent's entire reply, inside the form submission,
  # and timed out. Dispatching off-process fixed the timeout and left the
  # deeper problem: an agent that asked to be left alone was made busy by its
  # own answer arriving.
  #
  # Neither now. Answering writes a record and releases a blocker.
  describe "how it is delivered" do
    test "it is not delivered to the agent at all", %{scope: scope, agent: agent} do
      request = ask(scope, agent, "Well?")
      {:ok, _} = Notifications.answer_question_request(request.id, %{"Well?" => "fine"})

      refute_receive {:agent_dispatch, _id, _ref, _message}, 100
      refute_receive {:agent_message, _id, _text}, 100
    end

    # Criterion 3219 reads this off `read_agent_conversation` and requires the
    # transcript to be byte-identical across an answer. Here it is the same
    # claim one layer down: an answered question leaves the conversation alone,
    # so nothing an agent reads on its next turn is an interruption it did not
    # ask for.
    test "it writes nothing into the agent's conversation", ctx do
      before = message_texts(ctx.conversation)
      request = ask(ctx.scope, ctx.agent, "Which one?")

      {:ok, _} =
        Notifications.answer_question_request(request.id, %{"Which one?" => "the second"})

      assert message_texts(ctx.conversation) == before
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
