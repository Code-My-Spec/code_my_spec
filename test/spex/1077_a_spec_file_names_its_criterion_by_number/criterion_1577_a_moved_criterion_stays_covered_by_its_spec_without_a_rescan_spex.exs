defmodule CodeMySpecSpex.Story1077.Criterion1577Spex do
  @moduledoc """
  Story 1077 — A spec file names its criterion by number
  Criterion 1577 — A moved criterion stays covered by its spec without a rescan.

  Covers Rule "A spec file covers the criterion it names, wherever the file
  sits". Coverage matches the number a spec names, not the story its row was
  last filed under, so moving the criterion moves its coverage with it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.CriterionScript
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coverage follows a moved criterion", criterion: 1577 do
    scenario "a covered criterion moves to another story and its spec file is not touched" do
      given_ "a spec naming the criterion covers it on story A", context do
        story_a = CriterionScript.create_story(context.scope, "Story A", ["A thing that moves"])
        story_b = CriterionScript.create_story(context.scope, "Story B", [])
        [number] = context.scope |> CriterionScript.story_text(story_a) |> CriterionScript.numbers()

        :ok =
          Environments.write_file(
            context.environment,
            "test/spex/story_a/a_thing_that_moves_spex.exs",
            CriterionScript.spex_naming(number)
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.merge(context, %{story_b: story_b, number: number})}
      end

      when_ "the agent moves the criterion to story B, and the spec file is not touched", context do
        result =
          CriterionScript.run(context.scope, """
          return move_criterion({ criterion_id = "#{context.number}", target_story_id = "#{context.story_b}" })
          """)

        refute result.error?, "move_criterion failed: #{result.text}"
        {:ok, context}
      end

      then_ "story B's specs exist", context do
        text = CriterionScript.specs_requirement(context.scope, context.story_b)

        assert text =~ "**Status:** Satisfied",
               "the spec names criterion #{context.number}, now on story B. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
