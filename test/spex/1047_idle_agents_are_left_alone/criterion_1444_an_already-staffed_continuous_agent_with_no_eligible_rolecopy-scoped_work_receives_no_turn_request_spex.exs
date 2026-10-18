defmodule CodeMySpecSpex.Story1047.Criterion3546Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3546 — An already-staffed continuous agent with no eligible
  role/copy-scoped work receives no turn request.

  Observe the real harness process as well as the public conversation. An
  unchanged database transcript alone cannot prove that no turn was started.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

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

  spex "Only runnable agents receive turn requests", criterion: 1444 do
    scenario "An empty coding queue leaves the durable agent idle" do
      given_ "an already-staffed idle coding agent whose copy has no eligible coding work",
             context do
        context = given_a_feature_checkout(context, "spex_3546")
        context = ProjectStateFixtures.apply_project_kickoff(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        id = start_agent(context)
        on_exit(fn -> Machine.stop_agent(id) end)
        assert {:ok, %{busy?: false}} = Machine.status(id)
        assert Fixtures.role_queue_size(context.scope, id) == 0

        {:reply, conversation, _} = ReadAgentConversation.execute(%{agent_id: id}, frame(context))
        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: id,
           history_before: Machine.history(id),
           conversation_before: response_text(conversation),
           agents_before: Enum.sort(Machine.running())
         })}
      end

      when_ "the main agent enables continuous work and repeats that intent", context do
        for _ <- 1..2 do
          {:reply, response, _} =
            SetAgentContinuous.execute(
              %{agent_id: context.agent_id, continuous: true},
              frame(context)
            )

          refute response.isError, response_text(response)
        end

        {:ok, context}
      end

      then_ "no turn or message is delivered and the same durable agent remains idle", context do
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert Enum.sort(Machine.running()) == context.agents_before
        assert listing(context) =~ context.agent_id

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        {:ok, context}
      end
    end
  end
end
