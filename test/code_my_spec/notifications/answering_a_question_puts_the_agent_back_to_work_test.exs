defmodule CodeMySpec.Notifications.AnsweringAQuestionPutsTheAgentBackToWorkTest do
  @moduledoc """
  The other half of `denying_a_tap_out_puts_the_agent_back_to_work`.

  That test's own moduledoc states the defect: "`Work.consider_*` is
  edge-triggered on a graph change, a finished task, or continuous being
  switched on, and a person answering a gate is none of those." It was fixed for
  a denied tap-out and left unfixed for an answered question — the same shape
  with the same cause.

  `deliver_answer_content/2` deliberately says nothing to an *idle* agent, and
  that part is right: criterion 3219 exists because content pushed at an idle
  machine starts a turn, and the answer's own text tells the agent "this does
  not resume the task it blocked." The design assumes the agent comes back and
  collects it. For an agent whose only work IS the blocked task, nothing brings
  it back.

  Measured 2026-09-23 on Broken Oaths: three questions answered at 03:25:35
  released coding b01a95bb's blocker on story 950's promote. The task stayed
  `blocked`, `get_next_requirement` went on answering "ready", and the agent
  took no turn for five minutes while the copy's other four roles waited.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup do: CodeMySpecSpex.Fixtures.install_recording_agent_transport()

  # Staffed after the graph settles, so the only thing that can admit a turn is
  # the answer under test — `GraphWatcher.settle/1` fires its own
  # `consider_project`, and an agent standing there first is woken by that.
  defp asking_about_its_task(ctx) do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/answered-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    {:ok, agent} =
      TaskOwner.add_task(ctx.scope, agent, %{requirement_name: "story_promoted"})

    [task] = agent.tasks
    {:ok, agent} = TaskOwner.activate_task(ctx.scope, agent, task.id)

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        agent.id,
        %{
          "title" => "Which way",
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        task.id
      )

    {agent, conversation, request}
  end

  # The turn itself, off the recording transport: a resume or denial notice is
  # the whole turn prompt now (criterion 1864), so the transcript no longer
  # tells a turn from a note on the thread.
  defp admitted?(_conversation), do: not is_nil(turn_prompt())

  defp turn_prompt do
    receive do
      {:work_turn_requested, _agent_id, _ref, prompt} -> prompt
    after
      2_000 -> nil
    end
  end

  test "answering it offers the agent a turn", ctx do
    {_agent, conversation, request} = asking_about_its_task(ctx)

    :ok = Conversations.subscribe_conversation(conversation.id)

    {:ok, _answered} =
      Notifications.answer_question_request(request.id, %{"Which way?" => "that way"})

    assert_receive {:new_message, _}, 5_000

    assert admitted?(conversation),
           """
           The question that blocked this agent's task was answered and the agent
           was never offered a turn.

           An idle agent is deliberately not handed the answer as content, so
           the wake has to come through the work channel instead. Nothing else
           is coming: the blocker is cleared, the graph still holds the work, and
           the agent's only task is the one that was blocked.
           """
  end

  # 9f03455b: this test used to say an answer that released nothing woke
  # nobody. For a question asked without a task that left the asker idle with
  # its answer unread and, when the graph had no work for it, idle for good —
  # metric_flow's coder, f247789c, woken by hand. John, 10-01: offer an idle
  # continuous asker one turn that opens with the answer.
  defp asking_without_a_task(ctx, continuous?) do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: continuous?,
        status: :running,
        working_copy: "/tmp/answered-none-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        agent.id,
        %{
          "title" => "Idle curiosity",
          "questions" => [%{"question" => "Just wondering?", "options" => []}]
        },
        nil
      )

    :ok = Conversations.subscribe_conversation(conversation.id)

    {:ok, _answered} =
      Notifications.answer_question_request(request.id, %{"Just wondering?" => "no matter"})

    conversation
  end

  test "an answer to a question asked without a task offers the agent a turn with it", ctx do
    conversation = asking_without_a_task(ctx, true)

    assert_receive {:new_message, _}, 5_000

    opened_with_answer? =
      conversation
      |> Conversations.list_messages()
      |> Enum.any?(&(inspect(&1.content) =~ "A: no matter"))

    assert opened_with_answer?,
           "the answer released no task, and the idle agent that asked was never " <>
             "handed it — nothing else will bring it back"
  end

  test "an agent not in the loop collects it when it comes back", ctx do
    asking_without_a_task(ctx, false)

    refute_receive {:new_message, _}, 1_500
  end
end
