defmodule CodeMySpecSpex.Story561.Criterion3602Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3602 — The wave identifies how its tasks execute
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The wave identifies how its tasks execute" do
    scenario "The wave identifies how its tasks execute" do
      given_ "a story with a wave of actionable work", context do
        context = context |> Slice.base() |> Slice.child()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "each task in the wave says how it is executed", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        assert context.answer =~ "execution_type"
        assert context.answer =~ "sub_agent"
        assert context.answer =~ "orchestrated_by"
        assert context.answer =~ "develop_context"
        assert context.answer =~ "validation_type"
        assert context.answer =~ "automatic"
        {:ok, context}
      end
    end
  end
end
