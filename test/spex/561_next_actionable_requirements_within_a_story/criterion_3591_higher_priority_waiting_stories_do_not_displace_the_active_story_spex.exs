defmodule CodeMySpecSpex.Story561.Criterion3591Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3591 — Higher priority waiting stories do not displace the active story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Higher priority waiting stories do not displace the active story" do
    scenario "Higher priority waiting stories do not displace the active story" do
      given_ "a higher-priority story also assigned to this working copy", context do
        context = context |> Slice.base() |> Slice.child() |> Slice.waiting(assigned: true)
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the active story's work is still what comes back", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        refute Slice.offered?(context.answer, Slice.component(context, "Waiting").id)
        {:ok, context}
      end
    end
  end
end
