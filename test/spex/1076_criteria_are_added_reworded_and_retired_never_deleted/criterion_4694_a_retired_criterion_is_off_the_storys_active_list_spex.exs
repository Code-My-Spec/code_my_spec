defmodule CodeMySpecSpex.Story1076.Criterion4694Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4694 — A retired criterion is off the story's active list.

  Covers Rule "A retired criterion no longer counts toward its story".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retired criteria leave the active list but stay readable" do
    scenario "reading a story after one of its criteria is retired" do
      given_ "a criterion on story A is retired", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "A thing that stays",
            "A thing that was dropped"
          ])

        [kept, retired] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        result =
          CriterionScript.run(context.scope, """
          return retire_criterion({ criterion_id = "#{retired}" })
          """)

        refute result.error?, "retire_criterion failed: #{result.text}"

        {:ok, Map.merge(context, %{story: story, kept: kept, retired: retired})}
      end

      when_ "the agent reads story A", context do
        {:ok, Map.put(context, :text, CriterionScript.story_text(context.scope, context.story))}
      end

      then_ "the retired criterion is not among its active criteria", context do
        assert CriterionScript.numbers(context.text) == [context.kept],
               "expected only criterion #{context.kept} to be active. get_story showed:\n#{context.text}"

        {:ok, context}
      end

      and_ "the retired criterion can still be read by its number", context do
        result =
          CriterionScript.run(context.scope, """
          return get_criterion({ criterion_id = "#{context.retired}" })
          """)

        refute result.error?,
               "criterion #{context.retired} should still be readable by number. Got: #{result.text}"

        assert result.text =~ "A thing that was dropped"

        {:ok, context}
      end
    end
  end
end
