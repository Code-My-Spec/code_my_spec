defmodule CodeMySpecSpex.Story1047.Criterion3547Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3547 — Work for another role or working copy does not make
  an agent runnable.

  Exercise the other-role case on the same checkout. The QA frontier must
  be nonempty: two empty queues would not demonstrate role isolation.
  The real coding engine uses a local provider so even a routing regression
  cannot spend a live model turn.
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

  spex "Eligibility belongs to the agent's own role and working copy" do
    scenario "QA work on the same checkout leaves the coding agent idle" do
      given_ "QA work is available but a continuous coding agent has no eligible work", context do
        context = given_a_staffed_checkout(context, "spex_3547")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        frontier = Fixtures.actionable_work(context.scope)
        assert Enum.any?(frontier, fn {role, _} -> role == :qa end), inspect(frontier)
        refute Enum.any?(frontier, fn {role, _} -> role == :coding end), inspect(frontier)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(coding.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(coding.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(coding.id)

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: coding.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           coding_id: coding.id,
           history_before: Machine.history(coding.id),
           conversation_before: response_text(conversation)
         })}
      end

      when_ "the main agent reaffirms continuous work and eligibility is reconsidered", context do
        {:reply, response, _} =
          SetAgentContinuous.execute(
            %{agent_id: context.coding_id, continuous: true},
            frame(context)
          )

        refute response.isError, response_text(response)
        {:ok, context}
      end

      then_ "the coding agent remains idle without receiving a turn or operator message",
            context do
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.coding_id)
        assert Machine.history(context.coding_id) == context.history_before
        assert HeldProvider.seen() == []

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.coding_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        {:ok, context}
      end
    end
  end
end
