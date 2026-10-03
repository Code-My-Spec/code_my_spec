defmodule CodeMySpecSpex.Story983.Criterion8168Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 739 — Being certified ready for QA releases QA on the story.

  The ready-for-QA gate sits in front of `qa_complete` (via
  `story_issues_resolved`). Completing its task certifies the copy and stamps
  the commit, and the stamp is what opens the gate.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Certification opens the gate in front of QA", criterion: 739 do
    scenario "Being certified ready for QA releases QA on the story" do
      given_ "a coding agent holding the story's ready-for-QA task on a clean copy",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      given_ "the gate in front of QA is closed", context do
        body = story_requirements(context, context.story)
        refute satisfied?(body, "ready_for_qa"), body
        {:ok, context}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "the ready-for-QA gate is done", context do
        {error?, text} = context.answer
        refute error?, text
        body = story_requirements(context, context.story)
        assert satisfied?(body, "ready_for_qa"), body
        {:ok, Map.put(context, :body, body)}
      end

      then_ "and QA is the story's open work behind it", context do
        assert context.body =~ ~r/\[ \]\s+\*\*qa_complete\*\*/, context.body
        {:ok, context}
      end
    end
  end
end
