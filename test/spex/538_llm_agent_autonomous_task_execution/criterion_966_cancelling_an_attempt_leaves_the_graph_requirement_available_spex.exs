defmodule CodeMySpecSpex.Story538.Criterion2869Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 2869 — Cancelling an attempt leaves the graph requirement available.

  The agent cancels a real claim through MCP, then independently discovers and
  claims the still-unsatisfied requirement. Cancellation ends the attempt, not
  the requirement, and never creates the next attempt on the agent's behalf.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.CancelTask
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Cancellation ends only the recorded attempt", criterion: 966 do
    scenario "A durable agent cancels, discovers the requirement, and deliberately claims a new attempt" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "the agent has claimed a released story's unsatisfied specification requirement",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Cancellation preserves available work",
            description: "The agent can return to a requirement after cancelling its attempt",
            acceptance_criteria: ["The requirement stays available after cancellation"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        claim = %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(story.id)
        }

        {:reply, started, _} = StartTask.execute(claim, frame)
        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ task_id

        {:ok,
         Map.merge(context, %{agent_frame: frame, claim: claim, task_id: task_id, story: story})}
      end

      when_ "the authenticated agent cancels its active attempt", context do
        {:reply, response, _} =
          CancelTask.execute(%{task_id: context.task_id}, context.agent_frame)

        {:ok, Map.put(context, :cancel_result, response)}
      end

      then_ "the only recorded attempt is cancelled and nothing replaces it automatically",
            context do
        refute context.cancel_result.isError, response_text(context.cancel_result)
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[cancelled]"
        refute response_text(tasks) =~ "[active]"
        {:ok, context}
      end

      then_ "the agent can still discover the same requirement without claiming it", context do
        {:reply, available, _} =
          ListRequirements.execute(
            %{
              entity_type: "story",
              entity_id: to_string(context.story.id),
              requirement_name: "bdd_specs_exist",
              status: "unsatisfied"
            },
            context.agent_frame
          )

        refute available.isError, response_text(available)
        assert response_text(available) =~ "[ ] **bdd_specs_exist**"
        assert response_text(available) =~ context.story.title

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[cancelled]"
        refute response_text(tasks) =~ "[active]"
        {:ok, context}
      end

      then_ "only an explicit new claim starts a new attempt and preserves the cancelled history",
            context do
        {:reply, started, _} = StartTask.execute(context.claim, context.agent_frame)
        refute started.isError, response_text(started)
        new_task_id = extract_task_id!(started)
        assert new_task_id != context.task_id

        {:reply, active, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute active.isError, response_text(active)
        assert response_text(active) =~ "# Tasks (1)"
        assert response_text(active) =~ new_task_id
        refute response_text(active) =~ context.task_id

        {:reply, cancelled, _} = ListTasks.execute(%{status: "cancelled"}, context.agent_frame)
        refute cancelled.isError, response_text(cancelled)
        assert response_text(cancelled) =~ "# Tasks (1)"
        assert response_text(cancelled) =~ context.task_id
        refute response_text(cancelled) =~ new_task_id
        {:ok, context}
      end
    end
  end
end
