defmodule CodeMySpecSpex.Story686.Criterion1578Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1578 — A retired story's number is never given to another story.

  Covers Rule "The agent can create, read, update, and retire stories within
  the active project." Spec directories and issues name a story by its number;
  a reused number would point them at a different story.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retired story numbers stay taken", criterion: 1578 do
    scenario "the highest-numbered story is retired and another is created" do
      given_ "the project's highest story number is known", context do
        CriterionScript.create_story(context.scope, "First story", [])
        newest = CriterionScript.create_story(context.scope, "Newest story", [])

        number =
          context.scope |> CriterionScript.story_text(newest) |> CriterionScript.story_number()

        {:ok, Map.merge(context, %{newest: newest, highest: number})}
      end

      when_ "that story is retired and a new story is created", context do
        result =
          CriterionScript.run(
            context.scope,
            "return retire_story({ story_number = #{context.newest} })"
          )

        refute result.error?, "retire_story failed: #{result.text}"

        created = CriterionScript.create_story(context.scope, "Story after the retire", [])
        {:ok, Map.put(context, :created, created)}
      end

      then_ "the new story takes the next number, not the retired one", context do
        number =
          context.scope
          |> CriterionScript.story_text(context.created)
          |> CriterionScript.story_number()

        assert number == context.highest + 1,
               "expected story #{context.highest + 1}; got #{number}, reusing a retired story's number"

        {:ok, context}
      end
    end
  end
end
