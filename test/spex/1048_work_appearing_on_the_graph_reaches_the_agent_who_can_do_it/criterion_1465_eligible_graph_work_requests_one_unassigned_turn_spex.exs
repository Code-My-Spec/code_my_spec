defmodule CodeMySpecSpex.Story1048.Criterion3567Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3567 — Eligible graph work requests one unassigned turn.

  Follow the offered turn through the agent's explicit claim. The task list
  must be empty after admission and contain exactly the chosen task only after
  start_task. Criterion 3553 separately checks the absence of prompt preselection.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  spex "Available work offers a turn without choosing the agent's task", criterion: 1465 do
    scenario "Only the agent's explicit claim creates a task after turn admission" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3567")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3567 refund posting",
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
        {:ok, Map.merge(context, %{agent_id: agent.id, story: story})}
      end

      when_ "releasing the story changes graph eligibility", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        {:ok, context}
      end

      then_ "the graph has admitted one turn without claiming work", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:reply, tasks, _} = ListTasks.execute(%{agent_id: context.agent_id}, frame(context))
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end

      when_ "the agent explicitly chooses the context review", context do
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}

        {:reply, claimed, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story.number)
            },
            agent_frame
          )

        refute claimed.isError, response_text(claimed)
        {:ok, Map.put(context, :agent_frame, agent_frame)}
      end

      then_ "only the selected requirement is now an active task", context do
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "**bdd_specs_exist**"
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end
