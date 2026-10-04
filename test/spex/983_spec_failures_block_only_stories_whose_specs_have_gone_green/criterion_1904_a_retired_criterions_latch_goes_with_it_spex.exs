defmodule CodeMySpecSpex.Story983.Criterion1904Spex do
  @moduledoc """
  Story 983 — Criterion 1904: a retired criterion's latch goes with it.

  Retiring drops a criterion out of its story's coverage (its number is
  never reused, its spec file is left on disk) and, symmetrically, drops
  whatever it had latched — a restored criterion starts over the way a
  brand-new one does (criterion 1895), not re-admitted on a certification
  that happened before it came back.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retirement takes the criterion's latch with it", criterion: 1904 do
    scenario "a latched criterion is retired" do
      given_ "a story certified ready for QA, its one criterion latched", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        [criterion] = story.criteria
        {:ok, Map.merge(context, %{story: story, criterion: criterion})}
      end

      then_ "the criterion is latched before it is retired", context do
        assert criterion_latch(context, context.criterion) != nil
        {:ok, context}
      end

      when_ "the criterion is retired", context do
        response = retire_criterion(context, context.criterion)
        refute response.isError, inspect(response)
        {:ok, context}
      end

      then_ "its latch is gone along with it", context do
        assert criterion_latch(context, context.criterion) == nil,
               "retiring a criterion must take its latch with it"

        {:ok, context}
      end
    end
  end
end
