defmodule CodeMySpecSpex.Story1077.Criterion4670Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4670 — The name in the file wins over the filename.

  Covers Rule "A spec file covers the criterion it names, wherever the file
  sits". A filename that says one number and a `spex` call that says another
  is bound by the call: the filename is cosmetic.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The spex call decides, not the filename", criterion: 1546 do
    scenario "a file named for one criterion whose spex call names another" do
      given_ "a file named for the first of two criteria", context do
        story =
          CriterionScript.create_story(context.scope, "Two things", [
            "The first thing happens",
            "The second thing happens"
          ])

        [first, second] =
          context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        {:ok, Map.merge(context, %{story: story, first: first, second: second})}
      end

      when_ "its spex call names the second", context do
        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/two_things/criterion_#{context.first}_something_spex.exs",
            CriterionScript.spex_naming(context.second)
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "it covers the second and not the first", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "criterion #{context.first}",
               "criterion #{context.first} has no spec naming it and should be reported uncovered. Got:\n#{text}"

        refute text =~ "criterion #{context.second}",
               "criterion #{context.second} is named by the file and should not be reported uncovered. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
