defmodule CodeMySpec.AgentPerformance.CycleTimeTest do
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AgentPerformance.CycleTime
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a stage's time is bounded by the story's own promotion, not by real time", context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with an abandoned QA task",
        description: "A QA task left open past the story's own promotion."
      })

    now = DateTime.utc_now()
    released_at = DateTime.add(now, -10 * 3600, :second)
    promoted_at = DateTime.add(now, -5 * 3600, :second)

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: promoted_at})
      |> CodeMySpec.Repo.update()

    abandoned_qa_task = %{
      session_type: CodeMySpec.AgentTasks.QaStory,
      started_at: released_at,
      completed_at: nil,
      story_id: story.id,
      component_id: nil,
      blocked_at: nil,
      blocker_resolved_at: nil,
      blocker_type: nil
    }

    cycle_time = CycleTime.story(context.scope, story, [abandoned_qa_task])

    assert cycle_time.total_seconds == 5 * 3600

    assert cycle_time.stages[:qa] == 5 * 3600,
           "an open task's active time is not bounded to the story's own promotion"

    assert cycle_time.stages[:qa] <= cycle_time.total_seconds,
           "a stage's time exceeds the story's own total release-to-promotion time"
  end
end
