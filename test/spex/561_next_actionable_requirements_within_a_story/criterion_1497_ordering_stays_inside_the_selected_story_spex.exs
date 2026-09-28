defmodule CodeMySpecSpex.Story561.Criterion3599Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3599 — Ordering stays inside the selected story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Ordering stays inside the selected story", criterion: 1497 do
    scenario "Ordering stays inside the selected story" do
      given_ "several requirements actionable within the story", context do
        context =
          context
          |> Slice.base()
          |> Slice.child(["Reservations.Booking", "Reservations.Price"])
          |> Slice.waiting(assigned: true)

        {:ok, context}
      end

      when_ "the agent asks twice without changing anything", context do
        {:ok, Map.merge(context, %{answer: Slice.next(context), repeated: Slice.next(context)})}
      end

      then_ "both answers are identical, so ordering is stable inside the story", context do
        Slice.assert_active(context.answer, context, "ready")
        assert context.answer == context.repeated
        assert context.answer =~ "Wave: 2 requirement"
        assert context.answer =~ "Remaining: 0"
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Price").id)
        {:ok, context}
      end
    end
  end
end
