defmodule CodeMySpecSpex.Story983.Criterion1774Spex do
  @moduledoc """
  Story 983 — Criterion 1774: a story is ready for QA only once its ready-for-QA task completes against a
  clean working tree with a clean run of all four analyzers at HEAD's exact
  commit; completing it stamps the story with that commit.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Completing the task on a clean copy stamps the story with its HEAD", criterion: 1774 do
    scenario "the story's specs are green and every analyzer is clean at HEAD" do
      given_ "a coding agent holding the story's ready-for-QA task on a clean copy",
             context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, qa: :not_passed)
        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task with evaluate_task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "the task is done and the story is stamped with the copy's HEAD", context do
        head = head_of(context, context.agent_root)
        {error?, text} = context.answer
        refute error?, text
        assert text =~ head, text
        assert qa_stamp(context, context.story) == head
        {:ok, context}
      end

      then_ "and the story reads ready for QA", context do
        assert satisfied?(story_requirements(context, context.story), "ready_for_qa")
        {:ok, context}
      end
    end
  end

  spex "A task held on the retired bdd_specs_passing completes the same way", criterion: 1774 do
    scenario "an agent was holding the old task when it was renamed" do
      given_ "a coding agent holding a bdd_specs_passing task on a clean copy", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, qa: :not_passed)
        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story, legacy?: true) |> Map.put(:story, story)}
      end

      when_ "the agent completes it with evaluate_task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "it is certified and the story is stamped", context do
        {error?, text} = context.answer
        refute error?, text
        assert qa_stamp(context, context.story) == head_of(context, context.agent_root)
        {:ok, context}
      end
    end
  end

  spex "Uncommitted work refuses the certification", criterion: 1774 do
    scenario "the tree has an edit not committed" do
      given_ "a coding agent holding the task, analyzers clean, and an uncommitted edit",
             context do
        context = a_promotable_project(context)
        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":uncommitted"))
        story = a_promotable_story(context, qa: :not_passed)
        context = analyzers_are_current(context)
        {:ok, context |> a_held_ready_for_qa_task(story) |> Map.put(:story, story)}
      end

      when_ "the agent completes the task", context do
        {:ok, Map.put(context, :answer, complete_ready_for_qa(context))}
      end

      then_ "it is refused naming the file, and nothing is stamped", context do
        {_error?, text} = context.answer
        assert text =~ "war.ex", text
        assert qa_stamp(context, context.story) == nil
        {:ok, context}
      end
    end
  end
end
