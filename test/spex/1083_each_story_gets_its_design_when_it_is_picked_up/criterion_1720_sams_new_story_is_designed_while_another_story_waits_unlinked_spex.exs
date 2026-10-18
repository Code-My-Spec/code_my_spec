defmodule CodeMySpecSpex.Story1083.Criterion1720Spex do
  @moduledoc """
  Story 1083 — Each story gets its design when it is picked up
  Criterion 1720 — Sam's new story is designed while another story waits unlinked.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's new story is designed while another story waits unlinked", criterion: 1720 do
    scenario "the architect links the first story without waiting on the second" do
      given_ "the project already has a plan and two released stories with no component",
             context do
        app = context.project.module_name || "MyApp"

        plan_component =
          ComponentHelpers.create(context.scope,
            name: "Billing",
            module_name: "#{app}Web.BillingLive",
            type: "liveview"
          )

        story_a =
          StoryHelpers.create_story(context.scope,
            title: "Story A — needs a design",
            description: "First story waiting on architecture",
            acceptance_criteria: ["Story A criterion"]
          )

        story_b =
          StoryHelpers.create_story(context.scope,
            title: "Story B — also waiting",
            description: "Second story waiting on architecture",
            acceptance_criteria: ["Story B criterion"]
          )

        {:ok,
         Map.merge(context, %{
           plan_component: plan_component,
           story_a: story_a,
           story_b: story_b
         })}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"
        post_hook(context, "/api/hooks/session-start", %{"session_id" => session_id})
        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "a task is started for story A's component_linked requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "component_linked",
              entity_type: "story",
              entity_id: to_string(context.story_a.number),
              session_id: context.session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        task_id = extract_task_id!(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect designs the first story by linking it to the existing component",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        _response =
          ToolLibrary.run(
            "set_story_component",
            %{
              story_number: context.story_a.number,
              module_name: context.plan_component.module_name
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        evaluate_response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, evaluate_response)}
      end

      then_ "the first story is linked to its surface component", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        story_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story_a.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert response_text(story_response) =~
                 "**Component:** #{context.plan_component.module_name}"

        {:ok, context}
      end

      then_ "the design task completes even though the second story is still unlinked",
            context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected the design task to complete, but got: #{inspect(body)}"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        story_b_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story_b.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        refute response_text(story_b_response) =~ "**Component:**",
               "story B should still be unlinked"

        {:ok, context}
      end
    end
  end
end
