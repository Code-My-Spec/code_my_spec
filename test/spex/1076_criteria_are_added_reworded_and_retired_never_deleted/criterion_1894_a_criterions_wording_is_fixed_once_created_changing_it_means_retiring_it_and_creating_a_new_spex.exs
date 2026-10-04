defmodule CodeMySpecSpex.Story1076.Criterion1894Spex do
  @moduledoc """
  Story 1076 — Criteria are added and retired, never reworded or deleted
  Criterion 1894 — A criterion's wording is fixed once created; changing
  it means retiring it and creating a new criterion.

  Covers Rule "A criterion's wording is fixed once created".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Changing a criterion's wording retires it and creates a new one", criterion: 1894 do
    scenario "updating a criterion's description retires the old wording and adds a new criterion" do
      given_ "a criterion is active on story A with its original wording", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "The original thing happens"
          ])

        [number] =
          context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the agent changes its wording", context do
        result =
          CriterionScript.run(context.scope, """
          return update_criterion({ criterion_number = #{context.number}, description = "The reworded thing happens" })
          """)

        refute result.error?, "update_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "the original criterion still exists, unchanged, marked retired", context do
        result =
          CriterionScript.run(context.scope, """
          return get_criterion({ criterion_number = #{context.number} })
          """)

        refute result.error?,
               "criterion #{context.number} should still be readable after being reworded. Got: #{result.text}"

        assert result.text =~ "The original thing happens",
               "expected the old criterion's own wording to stay untouched. Got: #{result.text}"

        refute result.text =~ "The reworded thing happens",
               "the old criterion should not carry the new wording. Got: #{result.text}"

        assert result.text =~ ~r/retired/i, "expected it to read as retired. Got: #{result.text}"

        {:ok, context}
      end

      and_ "a new criterion exists on story A carrying the new wording", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "The reworded thing happens",
               "expected a new criterion with the reworded text on story A. get_story showed:\n#{text}"

        numbers = CriterionScript.numbers(text)

        refute context.number in numbers,
               "the retired original criterion should not be among story A's active criteria. get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
