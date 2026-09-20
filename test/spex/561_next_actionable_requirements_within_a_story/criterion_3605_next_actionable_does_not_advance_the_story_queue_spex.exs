defmodule CodeMySpecSpex.Story561.Criterion3605Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3605 — Next actionable does not advance the story queue
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Next actionable does not advance the story queue" do
    scenario "Next actionable does not advance the story queue" do
      given_ "an active story that is finished, and another story waiting", context do
        context = context |> Slice.complete() |> Slice.waiting()
        {:ok, context}
      end

      when_ "the agent asks what to work on again", context do
        {:ok, Map.merge(context, %{answer: Slice.next(context), repeated: Slice.next(context)})}
      end

      then_ "the waiting story has not been made active in its place", context do
        Slice.assert_active(context.answer, context, "complete")
        refute context.answer =~ "requirement_name=`"
        refute context.answer =~ "All requirements satisfied"
        Slice.assert_active(context.repeated, context, "complete")
        {:ok, context}
      end
    end
  end
end
