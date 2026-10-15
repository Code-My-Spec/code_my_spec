defmodule CodeMySpecSpex.Story1026.Criterion2045Spex do
  @moduledoc """
  Story 1026 — Removing a queued epic returns its unstarted stories to unassigned.
  Queue controls and rendered assignment state are the engineer's surface.
  Selectors name the required controls even before they are implemented.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.WorkingCopyHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Removing an epic releases its unstarted stories from the copy's queue", criterion: 2045 do
    scenario "Both unstarted stories become unassigned and remain in their epic" do
      given_ "a copy with an epic queued and neither story started", context do
        reply =
          WorkingCopyHelpers.join_working_copy(
            context,
            "/workspace/remove-epic",
            "Queued epic copy"
          )

        copy_id = reply[:working_copy_id]
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, created, _} = CreateEpic.execute(%{name: "Unstarted queued epic"}, frame)
        false = created.isError
        [_, epic_id] = Regex.run(~r/ID: ([^,\s]+)/, response_text(created))

        stories =
          for title <- ["First unstarted story", "Second unstarted story"] do
            story =
              StoryHelpers.create_story(context.scope,
                title: title,
                description: "Work not yet started",
                acceptance_criteria: ["It works"]
              )

            {:reply, assigned, _} =
              AssignStoryToEpic.execute(
                %{story_number: story.number, epic_name: "Unstarted queued epic"},
                frame
              )

            false = assigned.isError
            story
          end

        {:reply, placed, _} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id, working_copy_id: copy_id},
            frame
          )

        false = placed.isError

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies/#{copy_id}")

        {:ok, Map.merge(context, %{copy_view: view, queued_epic_id: epic_id, stories: stories})}
      end

      when_ "I remove that epic through the copy's queue control", context do
        context.copy_view
        |> element(
          "[data-test='remove-epic-from-queue'][data-epic-id='#{context.queued_epic_id}']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "the copy remains visible and neither story is queued there", context do
        assert has_element?(context.copy_view, "[data-test='working-copy-show']")

        for story <- context.stories do
          refute has_element?(
                   context.copy_view,
                   "[data-test='queued-story'][data-story-number='#{story.number}']"
                 )
        end

        {:ok, context}
      end

      then_ "the epic still contains both stories and reports them as unassigned", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.id}/epics")
        selector = "[data-test='epic'][data-epic-id='#{context.queued_epic_id}']"
        assert has_element?(board, selector)
        epic_html = board |> element(selector) |> render()

        assert has_element?(
                 board,
                 selector <> " [data-test='epic-assignment'][data-assigned-count='0']"
               )

        assert epic_html =~ "Unassigned"

        for story <- context.stories do
          assert epic_html =~ story.title
        end

        {:ok, context}
      end
    end
  end
end
