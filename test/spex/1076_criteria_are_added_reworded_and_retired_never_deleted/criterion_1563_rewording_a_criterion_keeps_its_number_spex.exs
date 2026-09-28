defmodule CodeMySpecSpex.Story1076.Criterion4687Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4687 — Rewording a criterion keeps its number.

  Covers Rule "A criterion keeps its number for its whole life".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Rewording keeps the number", criterion: 1563 do
    scenario "a reworded criterion is the same criterion" do
      given_ ~s(a criterion reads "A user logs in"), context do
        story = CriterionScript.create_story(context.scope, "Login", ["A user logs in"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, context |> Map.put(:story, story) |> Map.put(:number, number)}
      end

      when_ ~s(the agent rewords it to "A user signs in with a magic link"), context do
        result =
          CriterionScript.run(context.scope, """
          return update_criterion({ criterion_id = "#{context.number}", description = "A user signs in with a magic link" })
          """)

        refute result.error?, "update_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "it is still the same criterion number with the new wording", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "A user signs in with a magic link (criterion #{context.number})",
               "expected the new wording under criterion #{context.number}. get_story showed:\n#{text}"

        refute text =~ "A user logs in",
               "the old wording is still on the story. get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
