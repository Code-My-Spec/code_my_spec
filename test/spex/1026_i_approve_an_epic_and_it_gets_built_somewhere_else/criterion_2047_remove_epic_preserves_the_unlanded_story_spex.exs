defmodule CodeMySpecSpex.Story1026.Criterion2047Spex do
  @moduledoc """
  Story 1026 — Taking an epic off the queue preserves its team's unlanded story.
  The premise is certified and QA passed but not promoted: finishing those
  steps does not mean the story has landed. Removal uses the copy page; both
  teammates observe their retained story through the requirement tool.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Removing an epic keeps the team's current story until it lands", criterion: 2047 do
    scenario "Even a certified story awaiting promotion survives removal of its epic" do
      given_ "a team on an unlanded story with another story queued in the same epic", context do
        context =
          context
          |> Slice.main_copy()
          |> Slice.complete()
          |> Slice.waiting(assigned: true)

        answer = Slice.call(context, CreateEpic, %{name: "Epic containing current work"})
        [_, epic_id] = Regex.run(~r/ID: ([^,\s]+)/, answer)

        for story <- [context.story, context.waiting] do
          Slice.call(context, AssignStoryToEpic, %{
            story_number: story.number,
            epic_name: "Epic containing current work"
          })
        end

        Slice.call(context, AssignEpicToWorkingCopy, %{
          epic_id: epic_id,
          working_copy_id: context.scope.active_working_copy_id
        })

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        {:ok, Map.merge(context, %{copy_view: view, queued_epic_id: epic_id})}
      end

      when_ "I take that epic off the copy's queue", context do
        context.copy_view
        |> element(
          "[data-test='remove-epic-from-queue'][data-epic-id='#{context.queued_epic_id}']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "the unstarted story leaves the queue while both teammates retain the unlanded story",
            context do
        assert has_element?(context.copy_view, "[data-test='working-copy-show']")

        refute has_element?(
                 context.copy_view,
                 "[data-test='queued-story'][data-story-number='#{context.waiting.number}']"
               )

        for agent <- context.team do
          answer = Slice.next(context, %{agent_id: agent.id})
          assert answer =~ "# Story #{context.story.number}:"
          refute answer =~ "# Story #{context.waiting.number}:"
        end

        {:ok, context}
      end
    end
  end
end
