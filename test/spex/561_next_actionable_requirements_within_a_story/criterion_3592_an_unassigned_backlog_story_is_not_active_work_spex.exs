defmodule CodeMySpecSpex.Story561.Criterion3592Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3592 — An unassigned backlog story is not active work
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unassigned backlog story is not active work" do
    scenario "An unassigned backlog story is not active work" do
      given_ "an unassigned story sitting in the backlog beside the active one", context do
        context = context |> Slice.base() |> Slice.child() |> Slice.waiting()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        backlog = Slice.call(context, CodeMySpec.McpServers.Stories.Tools.ListStoryTitles, %{})
        {:ok, Map.merge(context, %{answer: Slice.next(context), backlog: backlog})}
      end

      then_ "only the active story's work is offered", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        assert context.backlog =~ context.waiting.title
        refute Slice.offered?(context.answer, Slice.component(context, "Waiting").id)
        {:ok, context}
      end
    end
  end
end
