defmodule CodeMySpecSpex.Story1076.Criterion4685Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4685 — A new criterion takes the next number in the project.

  Covers Rule "Every criterion has a number unique within its project".

  The number counts across the project, not per story: story B's first
  criterion follows story A's last.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Criterion numbers count across the project", criterion: 1561 do
    scenario "a criterion on a second story continues from the first story's" do
      given_ "story A has criteria 1, 2 and 3", context do
        CriterionScript.create_story(context.scope, "Story A", [
          "A first thing happens",
          "A second thing happens",
          "A third thing happens"
        ])

        {:ok, context}
      end

      and_ "story B has none", context do
        story_b = CriterionScript.create_story(context.scope, "Story B", [])
        {:ok, Map.put(context, :story_b, story_b)}
      end

      when_ "the agent adds a criterion to story B", context do
        result =
          CriterionScript.run(context.scope, """
          return add_criterion({ story_id = "#{context.story_b}", description = "B's first thing happens" })
          """)

        refute result.error?, "add_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "it is criterion 4", context do
        text = CriterionScript.story_text(context.scope, context.story_b)

        assert CriterionScript.numbers(text) == [4],
               "story B's first criterion should be number 4, after story A's 1, 2 and 3. " <>
                 "get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
