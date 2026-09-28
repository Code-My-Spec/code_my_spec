defmodule CodeMySpecSpex.Story686.Criterion1585Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1585 — Agent retires and rewords a criterion by its number.

  Covers Rule "Stories are named by their number and criteria by their number,
  everywhere." `(criterion N)` is what `get_story` shows, and `criterion_number`
  is what the criterion tools take.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A criterion is reworded and retired by its number", criterion: 1585 do
    scenario "the agent rewords one criterion and retires another" do
      given_ "story A has two criteria", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", ["First wording", "Second"])

        [kept, retired] =
          context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, Map.merge(context, %{story: story, kept: kept, retired: retired})}
      end

      when_ "the agent rewords the first and retires the second, by number", context do
        result =
          CriterionScript.run(context.scope, """
          update_criterion({ criterion_number = #{context.kept}, description = "Better wording" })
          return retire_criterion({ criterion_number = #{context.retired} })
          """)

        refute result.error?, "the criterion calls failed: #{result.text}"
        {:ok, context}
      end

      then_ "story A shows the reworded criterion under its number, and not the retired one",
            context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "Better wording (criterion #{context.kept})", text
        assert CriterionScript.numbers(text) == [context.kept], text

        {:ok, context}
      end
    end
  end
end
