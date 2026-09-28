defmodule CodeMySpecSpex.Story704.Criterion3581Spex do
  @moduledoc """
  Story 704, criterion 3581 — rejection requires deliberate resume of the linked task attempt.
  A real tap-out and permission rejection must leave the requirement discoverable,
  preserve continuous intent, and require an explicit resume of the same attempt.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Task tap-out rejection does not resume the linked attempt", criterion: 1479 do
    scenario "A human rejects task tap-out and the agent deliberately resumes the same attempt" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "the agent has claimed a released story's unsatisfied specification requirement",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Rejection permits deliberate resume",
            description: "The agent can resume its task only after the blocker is resolved",
            acceptance_criteria: ["A resolved task blocker permits explicit resume"]
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
          entity_id: to_string(story.number)
        }

        {:reply, started, _} = StartTask.execute(claim, frame)
        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ task_id

        {:ok,
         Map.merge(context, %{
           agent_frame: frame,
           claim: claim,
           task_id: task_id,
           story: story,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent requests task-scoped tap-out and the user denies it", context do
        {:reply, response, _} = TapOut.execute(%{task_id: context.task_id}, context.agent_frame)
        refute response.isError, response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, view, _} = live(context.conn, "/app/permissions/#{request_id}")
        assert has_element?(view, "[data-test='deny-permission']")

        view
        |> element("#permission-#{request_id}-confirm-deny [data-role='confirm-confirm']")
        |> render_click()

        assert has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end

      then_ "the linked attempt stays blocked and continuous intent remains unchanged",
            context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the agent explicitly resumes the requirement", context do
        {:reply, started, _} = StartTask.execute(context.claim, context.agent_frame)
        refute started.isError, response_text(started)
        assert extract_task_id!(started) == context.task_id
        {:ok, context}
      end

      then_ "the original attempt is active without a duplicate task", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[active]"
        refute response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[cancelled]"
        {:ok, context}
      end
    end
  end
end
