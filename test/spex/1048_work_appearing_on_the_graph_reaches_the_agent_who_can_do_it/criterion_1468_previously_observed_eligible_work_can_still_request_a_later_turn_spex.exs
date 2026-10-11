defmodule CodeMySpecSpex.Story1048.Criterion3570Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3570 — Previously observed eligible work permits a later turn.

  Let one graph-admitted turn finish without claiming work. No second story
  release or continuous toggle occurs: the turn-end event alone must reconsider
  the unchanged eligible work, reusing the same engine.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
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

  spex "Remaining work need not be newly discovered to permit a later turn", criterion: 1468 do
    scenario "A task-free turn end reconsiders unchanged eligible work" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3570")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3570 refund posting",
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

        assert {:ok, %{pid: pid}} =
                 Machine.start_agent(agent.id, context.copy, base_url: base_url)

        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)
        {:ok, Map.merge(context, %{agent_id: agent.id, engine_pid: pid, story: story})}
      end

      given_ "a graph-admitted turn completes without claiming its available work", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}
        {:reply, available, _} = GetNextRequirement.execute(%{}, agent_frame)
        refute available.isError, response_text(available)
        assert response_text(available) =~ "bdd_specs_exist"
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        HeldProvider.hold()
        assert length(HeldProvider.seen()) == 1

        {:ok,
         Map.merge(context, %{
           agent_frame: agent_frame,
           available_before: response_text(available)
         })}
      end

      when_ "the harness reports the task-free turn end with no new graph work", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        {:ok, context}
      end

      then_ "the same eligible work permits exactly one further unassigned turn", context do
        assert Process.alive?(context.engine_pid)
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 2

        {:reply, available, _} = GetNextRequirement.execute(%{}, context.agent_frame)
        refute available.isError, response_text(available)
        assert response_text(available) == context.available_before

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end
