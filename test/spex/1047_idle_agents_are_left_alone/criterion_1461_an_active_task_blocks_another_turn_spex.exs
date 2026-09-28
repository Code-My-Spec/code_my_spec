defmodule CodeMySpecSpex.Story1047.Criterion3563Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3563 — An active task blocks another turn.

  Claim through start_task, then request eligibility reconsideration through
  the main agent's tool. No turn is in flight: the active durable task itself
  must prevent admission until the agent explicitly dispositions it.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An active task prevents another work turn", criterion: 1461 do
    scenario "Continuous intent cannot bypass an undispositioned task" do
      given_ "an idle continuous QA agent owns an active QA task", context do
        context = given_a_staffed_checkout(context, "spex_3563")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) > 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:reply, claim, _} =
          StartTask.execute(
            %{
              requirement_name: "qa_complete",
              entity_type: "story",
              entity_id: to_string(context.story.id)
            },
            agent_frame
          )

        refute claim.isError, response_text(claim)
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "**qa_complete**"
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: agent.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           tasks_before: response_text(tasks),
           conversation_before: response_text(conversation),
           history_before: Machine.history(agent.id)
         })}
      end

      when_ "the main agent reaffirms continuous work", context do
        {:reply, response, _} =
          SetAgentContinuous.execute(
            %{agent_id: context.agent_id, continuous: true},
            frame(context)
          )

        refute response.isError, response_text(response)
        {:ok, context}
      end

      then_ "no work turn starts and the original task remains active", context do
        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == []
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, context}
      end
    end
  end
end
