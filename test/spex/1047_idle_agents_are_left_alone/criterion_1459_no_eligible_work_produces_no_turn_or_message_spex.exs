defmodule CodeMySpecSpex.Story1047.Criterion3561Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3561 — No eligible work produces no turn or message.

  Exercise repeated eligibility checks for QA, complementing the coding-role
  example. A continuous flag is intent, not permission to spend empty turns.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An empty QA queue remains silent across eligibility checks", criterion: 1459 do
    scenario "Reaffirming continuous intent does not manufacture QA work" do
      given_ "an idle continuous QA agent has no eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3561")
        context = ProjectStateFixtures.apply_project_kickoff(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

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
           history_before: Machine.history(agent.id),
           conversation_before: response_text(conversation)
         })}
      end

      when_ "the main agent repeatedly reaffirms continuous intent", context do
        for _ <- 1..3 do
          {:reply, response, _} =
            SetAgentContinuous.execute(
              %{agent_id: context.agent_id, continuous: true},
              frame(context)
            )

          refute response.isError, response_text(response)
        end

        {:ok, context}
      end

      then_ "the QA agent receives neither a turn nor an operator message", context do
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == []

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        {:ok, context}
      end
    end
  end
end
