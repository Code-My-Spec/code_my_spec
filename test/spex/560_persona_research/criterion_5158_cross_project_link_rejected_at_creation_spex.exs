defmodule CodeMySpecSpex.Story560.Criterion5158Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5158 — Cross-project link is rejected at link creation. Calling
  LinkPersonaToStory with a story_id that doesn't belong to the scope's
  active project returns an error response without creating a join row.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM attempts to link persona to a story on another project" do
    scenario "MCP response rejects with a cross-project error" do
      given_ :persona_exists

      given_ "a story exists on a different project", context do
        foreign_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Other Project",
            module_name: "OtherProject"
          })

        scope_with_foreign_project = %{
          context.scope
          | active_project: foreign_project,
            active_project_id: foreign_project.id
        }

        story =
          StoryHelpers.create_story(scope_with_foreign_project,
            title: "Foreign story",
            description: "This story belongs to a different project.",
            acceptance_criteria: ["Cross-project links are rejected at creation"]
          )

        {:ok, Map.put(context, :foreign_story_id, story.id)}
      end

      when_ "the PM calls LinkPersonaToStory with the foreign story_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.foreign_story_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the MCP response names the cross-project rejection", context do
        body = response_text(context.response)

        assert body =~ ~r/cross-project|does not belong|project/i,
               "expected MCP response to reject the cross-project link, got #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
