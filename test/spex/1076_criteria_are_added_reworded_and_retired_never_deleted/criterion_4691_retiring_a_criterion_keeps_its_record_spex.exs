defmodule CodeMySpecSpex.Story1076.Criterion4691Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4691 — Retiring a criterion keeps its record.

  Covers Rule "Criteria are retired, never deleted".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retiring keeps the record" do
    scenario "a retired criterion still exists, marked retired, on its story" do
      given_ "a criterion is active on story A", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing that will be retired"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ "the agent retires it", context do
        result =
          CriterionScript.run(context.scope, """
          return retire_criterion({ criterion_id = "#{context.number}" })
          """)

        refute result.error?, "retire_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "the criterion still exists, marked retired, on story A", context do
        result =
          CriterionScript.run(context.scope, """
          return get_criterion({ criterion_id = "#{context.number}" })
          """)

        refute result.error?,
               "criterion #{context.number} should still be readable once retired. Got: #{result.text}"

        assert result.text =~ "A thing that will be retired"
        assert result.text =~ ~r/retired/i, "expected it to read as retired. Got: #{result.text}"
        assert result.text =~ "Story A", "expected it to still name story A. Got: #{result.text}"

        {:ok, context}
      end
    end
  end
end
