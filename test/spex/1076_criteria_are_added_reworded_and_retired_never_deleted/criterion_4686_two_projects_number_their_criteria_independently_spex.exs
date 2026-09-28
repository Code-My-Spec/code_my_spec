defmodule CodeMySpecSpex.Story1076.Criterion4686Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4686 — Two projects number their criteria independently.

  Covers Rule "Every criterion has a number unique within its project".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each project numbers its own criteria" do
    scenario "a project's first criterion is 1 whatever another project holds" do
      given_ "project X's highest criterion is 40", context do
        CriterionScript.create_story(
          context.scope,
          "Busy story",
          Enum.map(1..40, &"Thing #{&1} happens")
        )

        {:ok, context}
      end

      and_ "project Y has none", context do
        project_y = Fixtures.project_fixture(context.scope, %{name: "Project Y", module_name: "ProjectY"})
        Fixtures.select_active_project(context.scope, project_y.id)

        scope_y = %{context.scope | active_project: project_y, active_project_id: project_y.id}
        story_y = CriterionScript.create_story(scope_y, "Y's story", [])

        {:ok, context |> Map.put(:scope_y, scope_y) |> Map.put(:story_y, story_y)}
      end

      when_ "a criterion is added to project Y", context do
        result =
          CriterionScript.run(context.scope_y, """
          return add_criterion({ story_id = "#{context.story_y}", description = "Y's first thing happens" })
          """)

        refute result.error?, "add_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "it is criterion 1 in project Y", context do
        text = CriterionScript.story_text(context.scope_y, context.story_y)

        assert CriterionScript.numbers(text) == [1],
               "project Y's first criterion should be number 1, not continue from project X's 40. " <>
                 "get_story showed:\n#{text}"

        {:ok, context}
      end
    end
  end
end
