defmodule CodeMySpecSpex.Story561.Criterion3609Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3609 — Failed QA keeps the working copy on the same story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Failed QA keeps the working copy on the same story", criterion: 1507 do
    scenario "Failed QA keeps the working copy on the same story" do
      given_ "a story whose QA attempt failed", context do
        context =
          context
          |> CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story()
          |> Slice.activate()
          |> Slice.waiting()

        {_story, task_id, _session} =
          CodeMySpecSpex.Fixtures.qa_story_task_fixture(context.scope, story: context.story)

        {:ok, Map.put(context, :qa_task_id, task_id)}
      end

      when_ "the agent asks what to work on", context do
        finding =
          Slice.call(context, "create_issue", %{
            title: "Story fails QA",
            severity: "high",
            description: "Reservation is lost after saving",
            story_number: context.story.number
          })

        [issue_id | _] =
          Regex.run(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, finding)

        result =
          Slice.call(context, "submit_qa_result", %{
            task_id: context.qa_task_id,
            status: "fail",
            issue_ids: [issue_id],
            scenarios: [
              %{
                name: "Save a reservation",
                status: "fail",
                observation: "Saved reservation is missing"
              }
            ]
          })

        assert result =~ "status:     fail"
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the copy stays on the same story rather than treating it as done", context do
        assert context.answer =~ "# Story #{context.story.number}:"
        refute context.answer =~ "Status: complete"
        refute Slice.offered?(context.answer, context.waiting.id)
        refute Slice.offered?(context.answer, Slice.component(context, "Waiting").id)
        {:ok, context}
      end
    end
  end
end
