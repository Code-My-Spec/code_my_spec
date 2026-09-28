defmodule CodeMySpecSpex.Story1076.Criterion4689Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4689 — Updating a story does not re-mint its criteria.

  Covers Rule "A criterion keeps its number for its whole life".

  `update_story`'s own documentation tells the agent to "include all
  acceptance criteria in the input", so an agent changing only the title
  sends the criteria back unchanged. Every unverified criterion used to be
  deleted and recreated under a new id on that call, which is how story
  1100's criteria were renumbered and lost their specs.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Updating a story leaves its criteria alone", criterion: 1565 do
    scenario "a title and description change keeps every criterion's number" do
      given_ "story A has two unverified criteria", context do
        story =
          CriterionScript.create_story(context.scope, "Story A", [
            "A first thing happens",
            "A second thing happens"
          ])

        numbers = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()
        {:ok, context |> Map.put(:story, story) |> Map.put(:numbers, numbers)}
      end

      when_ "the agent updates story A's title and description", context do
        result =
          CriterionScript.run(context.scope, """
          return update_story({
            story_number = #{context.story},
            title = "Story A, renamed",
            description = "A clearer description",
            acceptance_criteria = { "A first thing happens", "A second thing happens" }
          })
          """)

        refute result.error?, "update_story failed: #{result.text}"
        {:ok, context}
      end

      then_ "story A still has the same criteria with the same wording", context do
        text = CriterionScript.story_text(context.scope, context.story)
        [first, second] = context.numbers

        assert CriterionScript.numbers(text) == context.numbers,
               "expected criteria #{inspect(context.numbers)} to survive the update. get_story showed:\n#{text}"

        assert text =~ "A first thing happens (criterion #{first})"
        assert text =~ "A second thing happens (criterion #{second})"

        {:ok, context}
      end
    end
  end
end
