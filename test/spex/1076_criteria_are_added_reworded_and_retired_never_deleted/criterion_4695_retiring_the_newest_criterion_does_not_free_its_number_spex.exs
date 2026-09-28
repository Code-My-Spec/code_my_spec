defmodule CodeMySpecSpex.Story1076.Criterion4695Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4695 — Retiring the newest criterion does not free its number.

  Covers Rule "A number is never given to a second criterion".

  A reused number would bind a spec written for the old criterion to the new
  one, silently.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retired numbers stay taken" do
    scenario "retiring the highest criterion and adding another" do
      given_ "the project's highest criterion is 40", context do
        story =
          CriterionScript.create_story(
            context.scope,
            "Busy story",
            Enum.map(1..40, &"Thing #{&1} happens")
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "criterion 40 is retired and a new criterion is added", context do
        result =
          CriterionScript.run(context.scope, """
          local retired, err = retire_criterion({ criterion_id = "40" })
          if retired == nil then return "retire failed: " .. err.message end
          return add_criterion({ story_id = "#{context.story}", description = "A newer thing happens" })
          """)

        refute result.error?, "the calls failed: #{result.text}"
        refute result.text =~ "retire failed", result.text
        {:ok, context}
      end

      then_ "the new criterion is 41", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "A newer thing happens (criterion 41)",
               "expected the new criterion to be 41, not the retired 40 reused. get_story showed:\n" <>
                 String.slice(text, -600, 600)

        {:ok, context}
      end
    end
  end
end
