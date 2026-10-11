defmodule CodeMySpecSpex.Story983.Criterion1775Spex do
  @moduledoc """
  Story 983 — Criterion 1775: if no analysis run exists at HEAD when the ready-for-QA task completes,
  the gate starts one and tells the agent; the result reaches the agent when it
  lands.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completing with no run at HEAD starts one and waits", criterion: 1775 do
    scenario "nothing has analysed the copy's HEAD" do
      given_ "a coding agent holding the task on a copy never analysed", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "the task stays open, naming the commit being analysed", context do
        {_error?, text} = context.answer
        assert text =~ head_of(context, context.agent_root), text
        assert text =~ "told as each run", text
        {:ok, context}
      end

      then_ "and nothing is stamped yet", context do
        assert qa_stamp(context, context.story) == nil
        {:ok, context}
      end
    end
  end
end
