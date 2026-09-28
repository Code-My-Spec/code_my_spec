defmodule CodeMySpecSpex.Story560.Criterion5158Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 200 — A story number names a story in the active project only.
  Two projects each have a story numbered the same; linking a persona by that
  number links this project's story and leaves the other project's alone.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM links a persona by a number another project also uses", criterion: 200 do
    scenario "the link lands on this project's story" do
      given_ :persona_exists

      given_ "this project and another each have a story with the same number", context do
        local =
          StoryHelpers.create_story(context.scope,
            title: "Local story",
            description: "This story belongs to the active project.",
            acceptance_criteria: ["It is linked"]
          )

        foreign_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Other Project",
            module_name: "OtherProject"
          })

        foreign_scope = %{
          context.scope
          | active_project: foreign_project,
            active_project_id: foreign_project.id
        }

        # Numbers count per project, so the other project counts up to ours.
        for n <- 1..(local.number - 1)//1 do
          StoryHelpers.create_story(foreign_scope,
            title: "Other story #{n}",
            description: "Filler."
          )
        end

        foreign =
          StoryHelpers.create_story(foreign_scope,
            title: "Foreign story",
            description: "This story belongs to a different project.",
            acceptance_criteria: ["It is not linked"]
          )

        assert local.number == foreign.number,
               "the scenario needs both projects to hold the same number"

        {:ok, Map.put(context, :number, local.number)}
      end

      when_ "the PM links the persona to that story number", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_number: context.number},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the link names this project's story, not the other project's", context do
        body = response_text(context.response)

        refute context.response.isError, body
        assert body =~ ~s[story #{context.number} ("Local story")], body
        refute body =~ "Foreign story", body

        {:ok, context}
      end
    end
  end
end
