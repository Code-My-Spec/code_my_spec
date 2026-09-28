defmodule CodeMySpecSpex.Story561.Criterion3597Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3597 — Completed work disappears from the next wave
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completed work disappears from the next wave", criterion: 1495 do
    scenario "Completed work disappears from the next wave" do
      given_ "the offered work, now done", context do
        context = context |> Slice.base() |> Slice.child()
        {:ok, context}
      end

      when_ "the agent asks what to work on again", context do
        before = Slice.next(context)
        assert Slice.offered?(before, Slice.component(context, "Reservations.Booking").id)
        context = Slice.implement(context, "Reservations.Booking")
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the finished work is not offered a second time", context do
        assert context.answer =~ "# Story #{context.story.number}:"
        refute Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        assert context.answer =~ "bdd_specs_passing"
        {:ok, context}
      end
    end
  end
end
