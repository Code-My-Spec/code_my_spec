defmodule CodeMySpecSpex.Story561.Criterion3600Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3600 — A single eligible item is a one element wave
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A single eligible item is a one element wave" do
    scenario "A single eligible item is a one element wave" do
      given_ "exactly one actionable requirement in the story", context do
        context = context |> Slice.base() |> Slice.child()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the wave holds that one requirement and nothing is left over", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        assert context.answer =~ "Wave: 1 requirement"
        assert context.answer =~ "Remaining: 0"
        {:ok, context}
      end
    end
  end
end
