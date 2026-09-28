defmodule CodeMySpecSpex.Story560.Criterion5155Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5155 — Cross-project link attempt is rejected at the library
  boundary.

  The link is stored by id, and the library refuses an id from another
  project. The MCP tool cannot reach this — it names stories by number, which
  only ever resolves inside the active project (criterion 200) — so this is
  the guard for every other caller that holds an id.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Personas
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "cross-project link attempt", criterion: 197 do
    scenario "the library refuses a story id from another project" do
      given_ :persona_exists

      given_ "a story exists on a different project (same account)", context do
        foreign_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Sibling project",
            module_name: "SiblingProject"
          })

        foreign_scope = %{
          context.scope
          | active_project: foreign_project,
            active_project_id: foreign_project.id
        }

        story =
          StoryHelpers.create_story(foreign_scope,
            title: "Foreign story",
            description: "Lives on a different project.",
            acceptance_criteria: ["Cross-project links are rejected"]
          )

        {:ok,
         context
         |> Map.put(:foreign_story_id, story.id)
         |> Map.put(:foreign_story_number, story.number)}
      end

      when_ "a link to the foreign story's id is asked of the library", context do
        result =
          Personas.link_persona_to_story(
            context.scope,
            context.persona_id,
            context.foreign_story_id
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it is refused as crossing the project boundary", context do
        assert context.result == {:error, :cross_project},
               "expected a cross-project refusal, got #{inspect(context.result)}"

        {:ok, context}
      end
    end
  end
end
