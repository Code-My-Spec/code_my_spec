defmodule CodeMySpecSpex.Story1026.Criterion2044Spex do
  @moduledoc """
  Story 1026 — Add one story to a copy's queue without sending its whole epic.
  The copy page's queue control is the engineer's surface. Its selectors
  describe the required control and outcome, including before it is built.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.WorkingCopyHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An engineer queues one story without its epic's other stories", criterion: 2044 do
    scenario "Only the selected story appears on the destination copy's queue" do
      given_ "an empty copy and an epic containing two unassigned stories", context do
        reply =
          WorkingCopyHelpers.join_working_copy(
            context,
            "/workspace/single-story",
            "Single story copy"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "create_epic",
            %{name: "Two separate stories"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, _} = response

        stories =
          for title <- ["Selected story", "Other epic story"] do
            story =
              StoryHelpers.create_story(context.scope,
                title: title,
                description: "Work to queue separately",
                acceptance_criteria: ["It works"]
              )

            assigned =
              ToolLibrary.run(
                "assign_story_to_epic",
                %{story_number: story.number, epic_name: "Two separate stories"},
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            {:ok, _} = assigned
            story
          end

        [selected, other] = stories

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/working-copies/#{reply[:working_copy_id]}"
          )

        {:ok,
         Map.merge(context, %{
           copy_view: view,
           selected: selected,
           other: other,
           epic_response: response_text(response)
         })}
      end

      when_ "I add the selected story through the copy's queue control", context do
        context.copy_view
        |> form("[data-test='add-story-to-queue']",
          queue: %{story_number: context.selected.number}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the queue contains the selected story and excludes its epic's other story",
            context do
        assert has_element?(
                 context.copy_view,
                 "[data-test='queued-story'][data-story-number='#{context.selected.number}']"
               )

        refute has_element?(
                 context.copy_view,
                 "[data-test='queued-story'][data-story-number='#{context.other.number}']"
               )

        {:ok, context}
      end
    end
  end
end
