defmodule CodeMySpecSpex.Story1076.Criterion1894Spex do
  @moduledoc """
  Story 1076 — Criteria are added and retired, never reworded or deleted
  Criterion 1894 — A criterion's wording is fixed once created; changing
  it means retiring it and creating a new criterion.

  Covers Rule "A criterion's wording is fixed once created". There is no
  tool that rewords a criterion in place — rewording is retire_criterion
  followed by add_criterion, same as any other replacement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Changing a criterion's wording retires it and creates a new one", criterion: 1894 do
    scenario "there is no tool to reword a criterion in place" do
      given_ "a criterion is active on story A with its original wording", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "The original thing happens"
          ])

        [number] =
          context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the agent tries to reword it in place", context do
        result =
          CriterionScript.run(context.scope, """
          return update_criterion({ criterion_number = #{context.number}, description = "The reworded thing happens" })
          """)

        {:ok, Map.put(context, :in_place_attempt, result)}
      end

      then_ "there is no such tool", context do
        assert context.in_place_attempt.error?,
               "expected no tool named update_criterion to exist. Got: #{context.in_place_attempt.text}"

        assert context.in_place_attempt.text =~
                 ~r/not a tool .* carries|not in scope|unknown|nil value/i,
               "expected a tool-does-not-exist error. Got: #{context.in_place_attempt.text}"

        {:ok, context}
      end

      and_ "rewording is instead a deliberate retire and create", context do
        result =
          CriterionScript.run(context.scope, """
          retire_criterion({ criterion_number = #{context.number} })
          return add_criterion({ story_number = #{context.story}, description = "The reworded thing happens" })
          """)

        refute result.error?, "retire+create failed: #{result.text}"
        {:ok, context}
      end

      and_ "the original criterion still exists, unchanged, marked retired", context do
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
