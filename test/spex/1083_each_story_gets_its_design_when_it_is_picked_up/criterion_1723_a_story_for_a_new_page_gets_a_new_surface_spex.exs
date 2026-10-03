defmodule CodeMySpecSpex.Story1083.Criterion1723Spex do
  @moduledoc """
  Story 1083 — Each story gets its design when it is picked up
  Criterion 1723 — A story for a new page gets a new surface.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story for a new page gets a new surface", criterion: 1723 do
    scenario "the architect creates and links a new Reports surface" do
      given_ "Sam's project has no Reports page", context do
        app = context.project.module_name || "MyApp"

        # An existing plan, so the architect is in patch mode rather than
        # designing the whole project from nothing.
        _billing =
          ComponentHelpers.create(context.scope,
            name: "Billing",
            module_name: "#{app}Web.BillingLive",
            type: "liveview"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, before_response, _frame} = ListComponents.execute(%{}, frame)
        refute response_text(before_response) =~ "ReportsLive"

        story =
          StoryHelpers.create_story(context.scope,
            title: "Add a Reports page",
            description: "A brand new Reports page for the project",
            acceptance_criteria: ["Reports page shows up"]
          )

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
           app: app,
           story: story,
           session_id: session_id,
           task_id: task_id
         })}
      end

      when_ "the architect designs a story for a new Reports page", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        module_name = "#{context.app}Web.ReportsLive"

        {:reply, create_response, _frame} =
          CreateComponent.execute(
            %{name: "Reports", module_name: module_name, type: "liveview"},
            frame
          )

        refute create_response.isError,
               "expected create_component to succeed: #{inspect(create_response.content)}"

        {:reply, _response, _frame} =
          SetStoryComponent.execute(
            %{story_number: context.story.number, module_name: module_name},
            frame
          )

        {:reply, evaluate_response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.merge(context, %{module_name: module_name, evaluate_response: evaluate_response})}
      end

      then_ "a new Reports surface component exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listed, _frame} = ListComponents.execute(%{}, frame)

        assert response_text(listed) =~ context.module_name

        {:ok, context}
      end

      then_ "the story is linked to the new Reports component", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, story_response, _frame} =
          GetStory.execute(%{story_number: context.story.number}, frame)

        assert response_text(story_response) =~ "**Component:** #{context.module_name}"

        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected the design task to complete, but got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
