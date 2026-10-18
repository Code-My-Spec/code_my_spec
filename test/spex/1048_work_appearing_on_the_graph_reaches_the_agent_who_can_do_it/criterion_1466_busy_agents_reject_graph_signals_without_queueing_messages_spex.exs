defmodule CodeMySpecSpex.Story1048.Criterion3568Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3568 — Busy agents reject graph signals without queueing messages.

  Repeated graph updates must not stack future turns behind a busy engine.
  After its turn boundary, the same process takes one new turn and retains the
  completed conversation. Provider responses are local and explicitly held.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    exunit_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Busy agents reject graph signals without queueing messages", criterion: 1466 do
    scenario "Graph signals are discarded and current eligibility is checked at turn end" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3568")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is busy before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3568 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.watch_graph(context.scope)
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()

        assert {:ok, %{pid: engine_pid}} =
                 Machine.start_agent(agent.id, context.copy, base_url: base_url)

        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        assert {:ok, :started} =
                 Machine.send_message(agent.id, "current-turn", "Finish this user-requested turn")

        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: agent.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           engine_pid: engine_pid,
           story: story,
           conversation_before: response_text(conversation)
         })}
      end

      when_ "repeated releases update the graph while the turn is running", context do
        for _ <- 1..3 do
          :ok = Fixtures.mark_story_ready(context.scope, context.story)
          :ok = Fixtures.settle_graph(context.scope)
        end

        {:ok, context}
      end

      then_ "the current turn is not interrupted and no redundant turn is queued", context do
        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end

      when_ "the current turn finishes and its end is reported", context do
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        {:ok, completed_history} = Machine.history(context.agent_id)
        assert completed_history != []
        HeldProvider.hold()
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        HeldProvider.await_request()
        {:ok, Map.put(context, :completed_history, completed_history)}
      end

      then_ "remaining eligible work admits one new unassigned turn", context do
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 2
        assert Process.alive?(context.engine_pid)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == "No tasks."
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        {:ok, history} = Machine.history(context.agent_id)
        assert Enum.take(history, length(context.completed_history)) == context.completed_history
        assert length(history) > length(context.completed_history)
        assert Process.alive?(context.engine_pid)
        {:ok, context}
      end
    end
  end
end
