defmodule CodeMySpecSpex.Story1092.Criterion2013Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2013 -- Offer health is shown per role.

  Rule: Offer health is shown per role: claim rate, time to claim,
  ignored and declined offers.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    Fixtures.use_recording_transport(context)
  end

  spex "A role's claim rate reflects the offers its agents actually claimed",
    criterion: 2013 do
    scenario "agents in the coding role were offered work over a period" do
      given_ "one coding agent frees a task and a second coding agent claims it", context do
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        reply = join_working_copy(context, "/tmp/spex-2013", "the checkout")
        scope = Fixtures.in_memory_copy(context, reply.working_copy_id)

        ComponentHelpers.create(scope,
          name: "Example2013",
          type: "context",
          module_name: "CodeMySpecSpex.Example2013",
          description: "Fixture component for criterion 2013."
        )

        story =
          StoryHelpers.create_and_link(scope, "CodeMySpecSpex.Example2013",
            title: "Offered and claimed",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        fixture_context = %{scope: scope, execution_context: context.execution_context}
        %{persona_id: persona_id} = ProjectStateFixtures.apply_persona(fixture_context)

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(scope, story, persona_id: persona_id)

        :ok = ProjectStateFixtures.apply_bdd_spec_for_story(fixture_context, story)

        first = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2013")
        first_frame = %Frame{assigns: %{current_scope: scope, agent_id: first.id}}

        frame = %Frame{assigns: %{current_scope: scope}}

        resp =
          ToolLibrary.run(
            "set_active_story",
            %{story_number: story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, resp), inspect(resp)

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id:
                Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2013").id
            },
            Map.put(first_frame.assigns, :scope, first_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), inspect(started)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

        cancelled =
          ToolLibrary.run(
            "cancel_task",
            %{task_id: task_id},
            Map.put(first_frame.assigns, :scope, first_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, cancelled), inspect(cancelled)

        second =
          Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-2013",
            continuous: true
          )

        second_frame = %Frame{assigns: %{current_scope: scope, agent_id: second.id}}

        resp2 =
          ToolLibrary.run(
            "set_active_story",
            %{story_number: story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, resp2), inspect(resp2)

        {:ok, _ref} =
          Work.request_turn_if_runnable(scope, second, "a teammate's task freed up")

        claimed =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id:
                Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2013").id
            },
            Map.put(second_frame.assigns, :scope, second_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, claimed), inspect(claimed)

        {:ok, context |> Map.put(:scope, scope)}
      end

      when_ "I look at offer health", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = await_report(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "I see each role's claim rate and average time to claim", context do
        assert context.html =~ "coding", "the coding role's offer health is not shown at all"

        {:ok, context}
      end

      then_ "and how many offers were ignored or declined", context do
        assert context.html =~ "ignored" or context.html =~ "declined",
               "offer health does not account for ignored or declined offers at all"

        {:ok, context}
      end
    end
  end
end
