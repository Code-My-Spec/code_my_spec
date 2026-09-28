defmodule CodeMySpecSpex.Story560.Criterion5155Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5155 — Cross-project link attempt is rejected at the library
  boundary.

  The link is stored by id, and the library refuses an id from another
  project. The MCP tool cannot reach this — it names stories by number, which
  only ever resolves inside the active project (criterion 200). The persona
  page can: its link event carries a story id.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "cross-project link attempt", criterion: 197 do
    scenario "the persona page is asked to link another project's story id" do
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

        {:ok, Map.put(context, :foreign_story_id, story.id)}
      end

      when_ "the page's link event carries the foreign story's id", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/personas/#{context.persona_slug}"
          )

        html = render_hook(view, "link", %{"story_id" => to_string(context.foreign_story_id)})

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is refused as crossing the project boundary", context do
        assert context.html =~ "Could not link: :cross_project",
               "expected a cross-project refusal, got: #{context.html}"

        refute context.html =~ "Foreign story", "the foreign story must not appear as linked"

        {:ok, context}
      end
    end
  end
end
