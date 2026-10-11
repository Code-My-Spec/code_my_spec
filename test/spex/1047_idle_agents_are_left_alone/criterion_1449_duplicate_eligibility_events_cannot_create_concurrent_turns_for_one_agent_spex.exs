defmodule CodeMySpecSpex.Story1047.Criterion3551Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3551 — Duplicate eligibility events cannot create concurrent turns.

  Concurrent continuous-policy tool calls both reconsider eligibility. Hold
  the first real provider request so the engine's pending queue is observable:
  serialization alone is insufficient if duplicate signals queue another turn.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Duplicate eligibility signals admit only one turn", criterion: 1449 do
    scenario "Two simultaneous signals do not queue a redundant turn" do
      given_ "an idle continuous QA agent has eligible work and no active task", context do
        context = given_a_staffed_checkout(context, "spex_3551")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) > 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        {:reply, tasks, _} = ListTasks.execute(%{agent_id: agent.id}, frame(context))
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, Map.put(context, :agent_id, agent.id)}
      end

      when_ "duplicate continuous eligibility signals arrive together", context do
        1..2
        |> Task.async_stream(
          fn _ ->
            SetAgentContinuous.execute(
              %{agent_id: context.agent_id, continuous: true},
              frame(context)
            )
          end,
          max_concurrency: 2,
          timeout: 10_000
        )
        |> Enum.each(fn {:ok, {:reply, response, _}} ->
          refute response.isError, response_text(response)
        end)

        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "one turn is running and no second turn is queued or task assigned", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:reply, tasks, _} = ListTasks.execute(%{agent_id: context.agent_id}, frame(context))
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
