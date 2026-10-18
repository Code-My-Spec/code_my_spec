defmodule CodeMySpecSpex.Story983.Criterion1779Spex do
  @moduledoc """
  Story 983 — Criterion 1779: the ready-for-QA stamp clears when the story's spex are rewritten, its
  criteria change, its readiness changes, or it is unmarked.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Changing a certified story's criteria clears its stamp", criterion: 1779 do
    scenario "product adds a criterion after certification" do
      given_ "a story certified ready for QA through its held task", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "a criterion is added to the story", context do
        response = add_criterion(context, context.story, "It also works on Tuesdays")
        assert match?({:ok, _}, response), inspect(response)
        {:ok, context}
      end

      then_ "the stamp is gone and the story is no longer ready for QA", context do
        assert qa_stamp(context, context.story) == nil
        refute satisfied?(story_requirements(context, context.story), "ready_for_qa")
        {:ok, context}
      end
    end
  end
end
