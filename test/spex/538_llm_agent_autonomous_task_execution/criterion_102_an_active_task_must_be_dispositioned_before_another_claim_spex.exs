defmodule CodeMySpecSpex.Story538.Criterion1493Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1493 — An active task must be dispositioned before another claim.

  Two reviewed, released stories establish independently eligible work. A
  refusal must concern the existing active task, not missing prerequisites.
  Neither a normal second claim nor a supplied force flag may switch tasks.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Another eligible task cannot displace the active task", criterion: 102 do
    scenario "Normal and force-flagged claims both require explicit disposition" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two independent stories are eligible and the agent has claimed the first",
             context do
        [first, second] =
          Enum.map(["Keep the original claim", "Choose this only after disposition"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent eligible work for the explicit-disposition contract",
                acceptance_criteria: ["The stated behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            story
          end)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        available =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, available), response_text(available)

        Enum.each([first, second], fn story ->
          requirements =
            ToolLibrary.run(
              "list_requirements",
              %{
                entity_type: "story",
                entity_id: to_string(story.number),
                requirement_name: "bdd_specs_exist",
                status: "unsatisfied"
              },
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, requirements), response_text(requirements)
          assert response_text(requirements) =~ story.title
          assert response_text(requirements) =~ "[ ] **bdd_specs_exist**"
        end)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.number)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ task_id

        roster =
          ToolLibrary.run(
            "list_agents",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, roster), response_text(roster)

        {:ok,
         Map.merge(context, %{
           agent_frame: frame,
           second_story: second,
           task_id: task_id,
           tasks_before: response_text(tasks),
           roster_before: response_text(roster)
         })}
      end

      when_ "the agent requests the second task normally and with a force flag", context do
        claim = %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(context.second_story.number)
        }

        responses =
          Enum.map([claim, Map.put(claim, :force, true)], fn params ->
            {:reply, response, _} = StartTask.execute(params, context.agent_frame)
            response
          end)

        {:ok, Map.put(context, :responses, responses)}
      end

      then_ "both calls refuse the claim and instruct disposition without a force escape",
            context do
        Enum.each(context.responses, fn response ->
          assert response.isError, response_text(response)
          text = response |> response_text() |> String.downcase()
          assert text =~ context.task_id
          assert text =~ "active task"
          assert text =~ "complet"
          assert text =~ "block"
          assert text =~ "cancel"
          refute text =~ ~r/(?:retry|again|use|with).*force.*true/is
        end)

        {:ok, context}
      end

      then_ "no task switch, additional task, or staffing has occurred", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before

        roster =
          ToolLibrary.run(
            "list_agents",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns.current_scope
            )
          )

        assert match?({:ok, _}, roster), response_text(roster)
        assert response_text(roster) == context.roster_before
        {:ok, context}
      end
    end
  end
end
