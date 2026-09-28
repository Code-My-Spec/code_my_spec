defmodule CodeMySpecSpex.Story561.Criterion3594Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3594 — Satisfying a prerequisite unblocks dependent work
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Satisfying a prerequisite unblocks dependent work", criterion: 1492 do
    scenario "Satisfying a prerequisite unblocks dependent work" do
      given_ "the prerequisite that was blocking the story, now satisfied", context do
        context = context |> Slice.base() |> Slice.child()
        :ok = CodeMySpec.Environments.delete_file(context.environment, ".code_my_spec/qa/plan.md")
        {:ok, CodeMySpecSpex.GraphGivens.sync(context)}
      end

      when_ "the agent asks what to work on", context do
        before = Slice.next(context)
        assert before =~ "qa_setup"
        refute Slice.offered?(before, Slice.component(context, "Reservations.Booking").id)
        context = CodeMySpecSpex.ProjectStateFixtures.apply_qa_setup(context)
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the work that prerequisite gated is offered", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
