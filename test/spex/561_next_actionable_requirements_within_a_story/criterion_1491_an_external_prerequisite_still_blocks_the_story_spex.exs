defmodule CodeMySpecSpex.Story561.Criterion3593Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3593 — An external prerequisite still blocks the story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An external prerequisite still blocks the story", criterion: 1491 do
    scenario "An external prerequisite still blocks the story" do
      given_ "a project requirement the story waits on that is not met", context do
        context = context |> Slice.base() |> Slice.child()

        :ok = CodeMySpecSpex.ProjectStateFixtures.delete_qa_document(context.scope, "qa_plan")

        {:ok, CodeMySpecSpex.GraphGivens.sync(context)}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the story is blocked and names what it is waiting for", context do
        assert context.answer =~ "qa_setup"
        refute Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        refute context.answer =~ "Status: complete"
        {:ok, context}
      end
    end
  end
end
