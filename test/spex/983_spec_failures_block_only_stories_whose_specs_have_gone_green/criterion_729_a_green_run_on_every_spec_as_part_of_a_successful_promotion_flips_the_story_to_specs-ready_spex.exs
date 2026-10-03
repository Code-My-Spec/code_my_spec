defmodule CodeMySpecSpex.Story983.Criterion8158Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 729 — Promoting a story whose spex are all green on the certifying
  spex run latches it specs-ready; nothing else sets that latch.

  The latch means "promoted with its spex green" (John, 2026-10-02). Certifying
  a story ready for QA stamps a commit on it and leaves this latch alone:
  that is per copy and pre-merge, and must not make the story's red spex block
  other copies' promotions.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp latched?(context, story), do: Stories.get_story(context.scope, story.id).specs_ready

  spex "Promotion latches a green story specs-ready", criterion: 729 do
    scenario "the story's spex are all green on the certifying run" do
      given_ "an agent's copy with the story's spex green and analyzers clean at HEAD",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      when_ "the story is promoted", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "the story is latched specs-ready", context do
        refute context.response.isError, inspect(context.response)
        assert latched?(context, context.story)
        {:ok, context}
      end
    end
  end

  spex "Certifying for QA does not set the latch", criterion: 729 do
    scenario "the story is certified ready for QA but not promoted" do
      given_ "a coding agent holding the story's ready-for-QA task on a clean copy",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "the story is stamped ready for QA and not latched", context do
        {error?, text} = context.answer
        refute error?, text
        assert qa_stamp(context, context.story)
        refute latched?(context, context.story)
        {:ok, context}
      end
    end
  end
end
