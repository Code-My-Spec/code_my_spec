defmodule CodeMySpecSpex.Story1048.Criterion3558Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3558 — Racing graph and turn-end events admit at most one turn.

  Finish a real user turn locally, then deliver its end event concurrently
  with duplicate story-release signals. The held next provider request makes
  redundant queued turns observable instead of allowing them to drain away.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
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

  spex "Racing graph and turn-end signals share one admission decision" do
    scenario "Duplicate releases racing a turn end request only one new turn" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3558")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent has finished locally but not reported its turn end",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3558 refund posting",
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
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)

        assert {:ok, :started} =
                 Machine.send_message(agent.id, "current-turn", "Finish this user-requested turn")

        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        HeldProvider.release()
        :ok = Machine.await_idle(agent.id)
        HeldProvider.hold()

        {:ok, Map.merge(context, %{agent_id: agent.id, story: story})}
      end

      when_ "duplicate graph updates race the completed turn report", context do
        release_story = fn ->
          :ok = Fixtures.mark_story_ready(context.scope, context.story)
          :ok = Fixtures.settle_graph(context.scope)
        end

        finish_turn = fn ->
          :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        end

        [release_story, release_story, finish_turn]
        |> Task.async_stream(fn event -> event.() end, max_concurrency: 3, timeout: 30_000)
        |> Enum.each(fn result -> assert result == {:ok, :ok} end)

        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "remaining eligible work admits one new unassigned turn", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 2
        {:reply, tasks, _} = ListTasks.execute(%{agent_id: context.agent_id}, frame(context))
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
