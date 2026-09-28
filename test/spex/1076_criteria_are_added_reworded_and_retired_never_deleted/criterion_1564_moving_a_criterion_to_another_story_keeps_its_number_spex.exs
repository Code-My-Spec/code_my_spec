defmodule CodeMySpecSpex.Story1076.Criterion4688Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4688 — Moving a criterion to another story keeps its number.

  Covers Rule "A criterion keeps its number for its whole life".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Moving keeps the number", criterion: 1564 do
    scenario "a criterion moved to another story arrives under the same number" do
      given_ "a criterion is on story A", context do
        story_a =
          CriterionScript.create_story(context.scope, "Story A", [
            "A thing that belongs elsewhere"
          ])

        story_b = CriterionScript.create_story(context.scope, "Story B", [])

        [number] =
          context.scope |> CriterionScript.story_text(story_a) |> CriterionScript.numbers()

        {:ok, Map.merge(context, %{story_a: story_a, story_b: story_b, number: number})}
      end

      when_ "the agent moves it to story B", context do
        result =
          CriterionScript.run(context.scope, """
          return move_criterion({ criterion_number = #{context.number}, target_story_number = #{context.story_b} })
          """)

        refute result.error?, "move_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "story B has that criterion under the same number", context do
        text = CriterionScript.story_text(context.scope, context.story_b)

        assert CriterionScript.numbers(text) == [context.number],
               "expected story B to hold criterion #{context.number}. get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
