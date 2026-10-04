defmodule CodeMySpecSpex.Story1083.Criterion1722Spex do
  @moduledoc """
  Story 1083 — Each story gets its design when it is picked up
  Criterion 1722 — A story about an existing page reuses its surface.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story about an existing page reuses its surface", criterion: 1722 do
    scenario "linking to the existing Billing page creates no new surface component" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "Sam's project already has a Billing page component", context do
        app = context.project.module_name || "MyApp"

        billing =
          ComponentHelpers.create(context.scope,
            name: "Billing",
            module_name: "#{app}Web.BillingLive",
            type: "liveview"
          )

        story =
          StoryHelpers.create_story(context.scope,
            title: "Add a field to Billing",
            description: "Extends the existing Billing page with a new field",
            acceptance_criteria: ["New field appears on the Billing page"]
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, before_response, _frame} = ListComponents.execute(%{}, frame)

        session_id = "spex-#{System.unique_integer([:positive])}"
        post_hook(context, "/api/hooks/session-start", %{"session_id" => session_id})

        {:reply, task_response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "component_linked",
              entity_type: "story",
              entity_id: to_string(story.number),
              session_id: session_id
            },
            frame
          )

        task_id = extract_task_id!(response_text(task_response))

        {:ok,
         Map.merge(context, %{
           billing: billing,
           story: story,
           session_id: session_id,
           task_id: task_id,
           components_before: response_text(before_response)
         })}
      end

      when_ "the architect designs a story that adds a field to the Billing page", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetStoryComponent.execute(
            %{story_number: context.story.number, module_name: context.billing.module_name},
            frame
          )

        {:reply, evaluate_response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, evaluate_response)}
      end

      then_ "the story is linked to the existing Billing component", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, story_response, _frame} =
          GetStory.execute(%{story_number: context.story.number}, frame)

        assert response_text(story_response) =~ "**Component:** #{context.billing.module_name}"

        {:ok, context}
      end

      then_ "no new surface component was created", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, after_response, _frame} = ListComponents.execute(%{}, frame)

        assert response_text(after_response) == context.components_before,
               "expected the component list to be unchanged by reusing an existing surface"

        {:ok, context}
      end
    end
  end
end
