defmodule CodeMySpecSpex.Story704.Criterion1875Spex do
  @moduledoc """
  A pending task-scoped tap-out blocks its attempt, not the durable agent.
  The agent chooses another released story through the real task tool while
  the human decision remains pending. No blocked state is seeded.
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

  spex "Task-scoped tap-out leaves unrelated work available" do
    scenario "An agent blocks one attempt and chooses another before the user decides" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two released stories and a continuous agent holding the first task", context do
        [first, second] =
          Enum.map(["Refund calculation", "Receipt layout"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent work for task-scoped tap-out",
                acceptance_criteria: ["The behavior has a specification"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            story
          end)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.id)
            },
            frame
          )

        refute started.isError, response_text(started)

        {:ok,
         Map.merge(context, %{
           agent_frame: frame,
           task_id: extract_task_id!(started),
           second_story: second,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent requests tap-out for its active task", context do
        {:reply, response, _} = TapOut.execute(%{task_id: context.task_id}, context.agent_frame)
        refute response.isError, response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "the task is blocked immediately and continuous intent remains on", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the agent deliberately claims the other story", context do
        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.second_story.id)
            },
            context.agent_frame
          )

        refute started.isError, response_text(started)
        {:ok, Map.put(context, :second_task_id, extract_task_id!(started))}
      end

      then_ "only the new task is active and the original request still awaits a decision",
            context do
        assert context.second_task_id != context.task_id
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.second_task_id
        refute response_text(tasks) =~ context.task_id
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='approve-permission']")
        refute has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end
    end
  end
end
