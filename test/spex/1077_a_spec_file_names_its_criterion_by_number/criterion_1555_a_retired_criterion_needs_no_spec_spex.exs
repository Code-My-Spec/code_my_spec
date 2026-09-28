defmodule CodeMySpecSpex.Story1077.Criterion4679Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4679 — A retired criterion needs no spec.

  Covers Rule "A story's specs exist when every active criterion has a valid
  spec on this working copy".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retired criteria are not asked for specs", criterion: 1555 do
    scenario "two active criteria with specs and a retired one without" do
      given_ "the story has two active criteria with valid specs and one retired criterion with none",
             context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "The first thing happens",
            "The second thing happens",
            "A thing that was dropped"
          ])

        [first, second, dropped] =
          context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        for n <- [first, second] do
          :ok =
            Environments.write_file(
              context.environment,
              "test/spex/story_a/criterion_#{n}_spex.exs",
              CriterionScript.spex_naming(n, "Criterion#{n}")
            )
        end

        result =
          CriterionScript.run(
            context.scope,
            "return retire_criterion({ criterion_number = #{dropped} })"
          )

        refute result.error?, "retire_criterion failed: #{result.text}"

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the graph is computed", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "bdd_specs_exist is satisfied", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "**Status:** Satisfied",
               "the retired criterion needs no spec. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
