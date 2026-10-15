defmodule CodeMySpecSpex.Story1026.Criterion2046Spex do
  @moduledoc """
  Story 1026 — Removing one queued story leaves its epic's other stories queued.
  The engineer acts through the copy page and observes its queue and epic board.
  Selectors describe the required queue controls before they are implemented.
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

  spex "Removing one story preserves the rest of its epic's queue assignment", criterion: 2046 do
    scenario "One story leaves the queue while its sibling stays on the same copy" do
      given_ "a copy with two unstarted stories from one epic queued", context do
        reply =
          WorkingCopyHelpers.join_working_copy(
            context,
            "/workspace/remove-one-story",
            "Individual queue edits"
          )

        copy_id = reply[:working_copy_id]
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, created, _} = CreateEpic.execute(%{name: "Individually queued stories"}, frame)
        false = created.isError
        [_, epic_id] = Regex.run(~r/ID: ([^,\s]+)/, response_text(created))

        stories =
          for title <- ["Story to remove", "Story to keep queued"] do
            story =
              StoryHelpers.create_story(context.scope,
                title: title,
                description: "An unstarted member of the queued epic",
                acceptance_criteria: ["It works"]
              )

            {:reply, assigned, _} =
              AssignStoryToEpic.execute(
                %{story_number: story.number, epic_name: "Individually queued stories"},
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
        [removed, retained] = stories

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies/#{copy_id}")

        {:ok,
         Map.merge(context, %{
           copy_view: view,
           queued_epic_id: epic_id,
           removed: removed,
           retained: retained
         })}
      end

      when_ "I remove only the selected story from the copy's queue", context do
        context.copy_view
        |> element(
          "[data-test='remove-story-from-queue'][data-story-number='#{context.removed.number}']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "the sibling remains queued and the selected story is absent", context do
        assert has_element?(
                 context.copy_view,
                 "[data-test='queued-story'][data-story-number='#{context.retained.number}']"
               )

        refute has_element?(
                 context.copy_view,
                 "[data-test='queued-story'][data-story-number='#{context.removed.number}']"
               )

        {:ok, context}
      end

      then_ "both stories remain in their epic with only one still assigned", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.id}/epics")
        selector = "[data-test='epic'][data-epic-id='#{context.queued_epic_id}']"

        assert has_element?(
                 board,
                 selector <> " [data-test='epic-assignment'][data-assigned-count='1']"
               )

        epic_html = board |> element(selector) |> render()
        assert epic_html =~ context.removed.title
        assert epic_html =~ context.retained.title
        assert epic_html =~ "1 unassigned"

        {:ok, context}
      end
    end
  end
end
