defmodule CodeMySpecSpex.Story561.Criterion3603Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3603 — Completion is local to the active story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completion is local to the active story", criterion: 1501 do
    scenario "Completion is local to the active story" do
      given_ "an active story that is finished, and another story waiting", context do
        context = context |> Slice.complete() |> Slice.land() |> Slice.waiting()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the answer is complete for this story and offers no work", context do
        Slice.assert_active(context.answer, context, "complete")
        refute context.answer =~ "requirement_name=`"
        refute context.answer =~ "All requirements satisfied"
        {:ok, context}
      end
    end
  end
end
