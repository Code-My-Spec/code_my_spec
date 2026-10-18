defmodule CodeMySpecSpex.Story704.Criterion3580Spex do
  @moduledoc """
  Story 704, criterion 3580 — approval cancels only the linked task attempt.
  A real tap-out and permission approval must leave the requirement discoverable,
  preserve continuous intent, and require an explicit claim for a new attempt.
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

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Task tap-out approval cancels only the linked attempt", criterion: 1478 do
    scenario "A human approves task tap-out and the agent can deliberately reclaim its requirement" do
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
          entity_id: to_string(story.number)
        }

        started =
          ToolLibrary.run(
            "start_task",
            claim,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        task_id = extract_task_id!(started)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
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

      when_ "the agent requests task-scoped tap-out and the user approves it", context do
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
        {:ok, view, _} = live(context.conn, "/app/permissions/#{request_id}")
        view |> element("[data-test='approve-permission']") |> render_click()
        assert has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end

      then_ "the only recorded attempt is cancelled and nothing replaces it automatically",
            context do
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
        assert response_text(tasks) =~ "[cancelled]"
        refute response_text(tasks) =~ "[active]"
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "the agent can still discover the same requirement without claiming it", context do
        available =
          ToolLibrary.run(
            "list_requirements",
            %{
              entity_type: "story",
              entity_id: to_string(context.story.number),
              requirement_name: "bdd_specs_exist",
              status: "unsatisfied"
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns.current_scope
            )
          )

        assert match?({:ok, _}, available), response_text(available)
        assert response_text(available) =~ "[ ] **bdd_specs_exist**"
        assert response_text(available) =~ context.story.title

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
        assert response_text(tasks) =~ "[cancelled]"
        refute response_text(tasks) =~ "[active]"
        {:ok, context}
      end

      then_ "only an explicit new claim starts a new attempt and preserves the cancelled history",
            context do
        started =
          ToolLibrary.run(
            "start_task",
            context.claim,
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, started), response_text(started)
        new_task_id = extract_task_id!(started)
        assert new_task_id != context.task_id

        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ "# Tasks (1)"
        assert response_text(active) =~ new_task_id
        refute response_text(active) =~ context.task_id

        cancelled =
          ToolLibrary.run(
            "list_tasks",
            %{status: "cancelled"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, cancelled), response_text(cancelled)
        assert response_text(cancelled) =~ "# Tasks (1)"
        assert response_text(cancelled) =~ context.task_id
        refute response_text(cancelled) =~ new_task_id
        {:ok, context}
      end
    end
  end
end
