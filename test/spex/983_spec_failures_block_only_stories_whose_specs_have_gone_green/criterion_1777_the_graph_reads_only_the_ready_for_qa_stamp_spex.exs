defmodule CodeMySpecSpex.Story983.Criterion1777Spex do
  @moduledoc """
  Story 983 — Criterion 1777: the graph reads only the ready-for-QA stamp; no requirement is satisfied
  or held by analysis results or problem counts directly.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Green analysis without a stamp is not ready for QA", criterion: 1777 do
    scenario "every analyzer clean and the story's specs green, nothing certified" do
      given_ "a story whose specs are green and every analyzer clean at HEAD", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)
        context = analyzers_are_current(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the story's requirements are read", context do
        {:ok, Map.put(context, :body, story_requirements(context, context.story))}
      end

      then_ "ready_for_qa is not satisfied — nothing certified it", context do
        refute satisfied?(context.body, "ready_for_qa"), context.body
        {:ok, context}
      end
    end
  end

  spex "A later red spec does not move a stamped story", criterion: 1777 do
    scenario "a spex failure is recorded after certification" do
      given_ "a story certified ready for QA through its held task", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)
        context = analyzers_are_current(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "another story's red spec is recorded and the requirements are read", context do
        _ = a_promotable_story(context, title: "A later red story", red?: true)
        {:ok, Map.put(context, :body, story_requirements(context, context.story))}
      end

      then_ "ready_for_qa still reads the stamp", context do
        assert satisfied?(context.body, "ready_for_qa"), context.body
        {:ok, context}
      end
    end
  end
end
