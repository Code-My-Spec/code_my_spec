defmodule CodeMySpecSpex.Story1048.Criterion3555Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3555 — A graph change with no eligible work requests no turn.

  Releasing coding work changes the graph without creating QA work. A real
  QA engine must remain idle, and its public conversation must remain unchanged.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Graph changes without eligible QA work leave QA idle", criterion: 1453 do
    scenario "Releasing coding work does not request a QA turn" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3555")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous QA agent is idle before coding work is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3555 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.watch_graph(context.scope)
        agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: agent.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           story: story,
           conversation_before: response_text(conversation),
           history_before: Machine.history(agent.id)
         })}
      end

      when_ "releasing the story changes graph eligibility", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "the existing QA agent receives neither a turn nor a message", context do
        {:reply, work, _} = GetNextRequirement.execute(%{}, frame(context))
        refute work.isError, response_text(work)
        assert response_text(work) =~ "bdd_specs_exist"

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert Machine.running?(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end
    end
  end
end
