defmodule CodeMySpecSpex.Story686.Criterion1580Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1580 — A retired story is restored under its number, with its
  criteria.

  Covers Rule "The agent can create, read, update, and retire stories within
  the active project." Nothing is deleted, so a mistaken retire is undone by
  restoring: same number, same criteria. It comes back parked, because
  releasing it again is its own decision.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Restoring brings a story back as it was", criterion: 1580 do
    scenario "a retired story with a criterion is restored" do
      given_ "story A, with a criterion, was retired", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        text = CriterionScript.story_text(context.scope, story)
        [criterion] = CriterionScript.numbers(text)

        result = CriterionScript.run(context.scope, "return retire_story({ story_id = \"#{story}\" })")
        refute result.error?, "retire_story failed: #{result.text}"

        {:ok,
         Map.merge(context, %{
           story: story,
           story_number: CriterionScript.story_number(text),
           criterion: criterion
         })}
      end

      when_ "the agent restores story A", context do
        result = CriterionScript.run(context.scope, "return restore_story({ story_id = \"#{context.story}\" })")
        refute result.error?, "restore_story failed: #{result.text}"
        {:ok, context}
      end

      then_ "story A is back in the backlog under the same number, parked", context do
        titles = CriterionScript.run(context.scope, "return list_story_titles({})").text
        assert titles =~ "Story A", "the restored story is not in the backlog. Got: #{titles}"

        text = CriterionScript.story_text(context.scope, context.story)

        assert CriterionScript.story_number(text) == context.story_number,
               "expected story #{context.story_number}. Got:\n#{text}"

        assert text =~ "Ready for development: false", "a restored story should come back parked. Got:\n#{text}"

        {:ok, context}
      end

      and_ "its criterion is active on it again", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert CriterionScript.numbers(text) == [context.criterion],
               "expected criterion #{context.criterion} active on the story. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
