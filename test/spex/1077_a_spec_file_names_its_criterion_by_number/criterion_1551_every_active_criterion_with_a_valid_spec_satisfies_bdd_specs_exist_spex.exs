defmodule CodeMySpecSpex.Story1077.Criterion4675Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4675 — Every active criterion with a valid spec satisfies
  bdd_specs_exist.

  Covers Rule "A story's specs exist when every active criterion has a valid
  spec on this working copy".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Full coverage satisfies the requirement", criterion: 1551 do
    scenario "three active criteria, each with a valid spec naming it" do
      given_ "the story has three active criteria", context do
        story =
          CriterionScript.create_story(context.scope, "Three things", [
            "The first thing happens",
            "The second thing happens",
            "The third thing happens"
          ])

        numbers = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()
        {:ok, context |> Map.put(:story, story) |> Map.put(:numbers, numbers)}
      end

      and_ "each has a valid spec on this working copy naming it", context do
        for n <- context.numbers do
          :ok =
            ExecutionContexts.write_file(
              context.execution_context,
              "test/spex/three_things/criterion_#{n}_spex.exs",
              CriterionScript.spex_naming(n, "Criterion#{n}")
            )
        end

        {:ok, context}
      end

      when_ "the graph is computed", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "bdd_specs_exist is satisfied for the story", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)
        assert text =~ "**Status:** Satisfied", "every criterion has a spec. Got:\n#{text}"
        {:ok, context}
      end
    end
  end
end
