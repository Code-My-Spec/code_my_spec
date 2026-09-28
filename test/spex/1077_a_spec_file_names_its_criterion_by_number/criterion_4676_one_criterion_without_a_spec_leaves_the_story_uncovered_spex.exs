defmodule CodeMySpecSpex.Story1077.Criterion4676Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4676 — One criterion without a spec leaves the story uncovered.

  Covers Rule "A story's specs exist when every active criterion has a valid
  spec on this working copy". The agent is told which one is missing, by the
  number it would put in the file.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A missing spec is named" do
    scenario "three active criteria, two with specs" do
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

      and_ "only two have specs", context do
        [first, second, _third] = context.numbers

        for n <- [first, second] do
          :ok =
            Environments.write_file(
              context.environment,
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

      then_ "bdd_specs_exist is unsatisfied and names the uncovered criterion", context do
        [_first, _second, third] = context.numbers
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "**Status:** Not satisfied", "one criterion has no spec. Got:\n#{text}"
        assert text =~ "criterion #{third}", "the uncovered criterion should be named. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
