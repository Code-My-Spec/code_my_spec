defmodule CodeMySpecSpex.Story1047.Criterion3562Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3562 — Other-role work does not make coding runnable.

  Both roles run on one checkout. QA actually takes a turn, so silence from
  coding cannot be explained by a broken transport or a universally empty graph.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Only the role with eligible work receives a turn", criterion: 1460 do
    scenario "QA takes its turn while coding remains idle on the same checkout" do
      given_ "continuous coding and QA agents are idle with only QA work available", context do
        context = given_a_staffed_checkout(context, "spex_3562")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        assert Fixtures.role_queue_size(context.scope, qa.id) > 0
        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [coding.id, qa.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
          assert {:ok, %{busy?: false, queued: 0}} = Machine.status(id)
        end

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: coding.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           coding_id: coding.id,
           qa_id: qa.id,
           coding_history: Machine.history(coding.id),
           coding_conversation: response_text(conversation)
         })}
      end

      when_ "the main agent reconsiders continuous work for both roles", context do
        for id <- [context.qa_id, context.coding_id] do
          {:reply, response, _} =
            SetAgentContinuous.execute(%{agent_id: id, continuous: true}, frame(context))

          refute response.isError, response_text(response)
        end

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "QA is running one turn and coding has received nothing", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.qa_id)
        assert length(HeldProvider.seen()) == 1
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.coding_id)
        assert Machine.history(context.coding_id) == context.coding_history

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.coding_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.coding_conversation
        {:ok, context}
      end
    end
  end
end
