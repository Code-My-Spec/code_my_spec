defmodule CodeMySpecSpex.Story1077.Criterion4678Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 4678 — An invalid spec does not cover its criterion.

  Covers Rule "A story's specs exist when every active criterion has a valid
  spec on this working copy". A spec that does not compile names its
  criterion and still covers nothing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only a valid spec covers", criterion: 1554 do
    scenario "a spec naming the criterion fails to compile" do
      given_ "a spec naming the criterion fails to compile", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        [number] = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()

        broken =
          number
          |> CriterionScript.spex_naming()
          |> String.replace(
            "{:ok, context}\n      end\n\n      when_",
            "{:ok, context\n      end\n\n      when_"
          )

        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            "test/spex/story_a/broken_spex.exs",
            broken
          )

        {:ok, Map.merge(context, %{story: story, number: number})}
      end

      when_ "the graph is computed", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the criterion is uncovered", context do
        text = CriterionScript.specs_requirement(context.scope, context.story)

        assert text =~ "**Status:** Not satisfied",
               "the only spec does not compile. Got:\n#{text}"

        assert text =~ "criterion #{context.number}"

        {:ok, context}
      end
    end
  end
end
