defmodule CodeMySpecSpex.Story983.Criterion1776Spex do
  @moduledoc """
  Story 983 — Criterion 1776: ready-for-QA scopes problems as promotion does: the story's own spex must
  be green; another story's red spex count only if that story is promoted.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story's own red spex refuse it", criterion: 1776 do
    scenario "the story's own spec is red" do
      given_ "a coding agent holding the task, the copy clean, and this story's spec failing",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context, red?: true)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "it is refused naming its spex, and nothing is stamped", context do
        {_error?, text} = context.answer
        assert text =~ "spex", text
        assert qa_stamp(context, context.story) == nil
        {:ok, context}
      end
    end
  end

  spex "Another, unpromoted story's red spex do not hold it", criterion: 1776 do
    scenario "another story's spec is red" do
      given_ "a coding agent holding this story's task, it green, and another story red",
             context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        _other = a_promotable_story(context, title: "Someone else's story", red?: true)
        story = a_promotable_story(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes this story's task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "this story is stamped regardless", context do
        {error?, text} = context.answer
        refute error?, text
        assert qa_stamp(context, context.story) == head_of(context, context.agent_root)
        {:ok, context}
      end
    end
  end
end
