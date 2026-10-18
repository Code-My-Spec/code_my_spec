defmodule CodeMySpecSpex.Story704.Criterion1875Spex do
  @moduledoc """
  A pending task-scoped tap-out blocks its attempt, not the durable agent.
  The agent chooses unrelated component work through the real task tool while
  the human decision remains pending; it stays with its team's story rather
  than taking another (a31f1cd6: the team sees a story through together). No blocked state is seeded.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    # The tap-out frees the agent, so the graph offers it work (1759); recorded
    # rather than run, so no background turn races the agent's own choice.
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Task-scoped tap-out leaves unrelated work available", criterion: 444 do
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

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.number)
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)

        {:ok,
         Map.merge(context, %{
           agent_frame: frame,
           task_id: extract_task_id!(started),
           second_story: second,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent requests tap-out for its active task", context do
        response =
          ToolLibrary.run(
            "tap_out",
            %{task_id: context.task_id},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "the task is blocked immediately and continuous intent remains on", context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the agent deliberately claims unrelated component work", context do
        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, started), response_text(started)
        {:ok, Map.put(context, :second_task_id, extract_task_id!(started))}
      end

      then_ "only the new task is active and the original request still awaits a decision",
            context do
        assert context.second_task_id != context.task_id

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
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
