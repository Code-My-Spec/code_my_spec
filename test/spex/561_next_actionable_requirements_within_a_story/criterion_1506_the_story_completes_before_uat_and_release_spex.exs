defmodule CodeMySpecSpex.Story561.Criterion3608Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3608 — The story completes before UAT and release
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The story completes before UAT and release", criterion: 1506 do
    scenario "The story completes before UAT and release" do
      given_ "a story complete for this copy, with releases enabled", context do
        context = context |> Slice.complete() |> Slice.land()
        CodeMySpecSpex.Fixtures.enable_devops(context.scope)
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the story reads complete before UAT and release, not after", context do
        Slice.assert_active(context.answer, context, "complete")
        refute context.answer =~ "requirement_name=`"
        refute context.answer =~ "All requirements satisfied"
        refute context.answer =~ "requirement_name=`deploy`"
        refute context.answer =~ "requirement_name=`release`"
        {:ok, context}
      end
    end
  end
end
