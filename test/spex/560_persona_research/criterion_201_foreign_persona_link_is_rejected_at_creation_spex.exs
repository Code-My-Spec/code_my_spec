defmodule CodeMySpecSpex.Story560.Criterion201Spex do
  @moduledoc """
  Story 560 — Persona Research. A persona from another project cannot be linked
  to a story in the active project, even when both projects share an account.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A foreign persona cannot be linked to a story in the active project", criterion: 201 do
    scenario "the MCP tool rejects the foreign persona without creating a join row" do
      given_ "a story exists on the active project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Active project story",
            description: "A story that must not acquire a foreign persona",
            acceptance_criteria: ["Only this project's personas can be linked"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      and_ "a persona exists on a different project in the same account", context do
        foreign_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Foreign Persona Project",
            module_name: "ForeignPersonaProject"
          })

        foreign_scope = %{
          context.scope
          | active_project: foreign_project,
            active_project_id: foreign_project.id
        }

        {:ok, create_response} =
          ToolLibrary.run(
            "create_persona",
            %{slug: "foreign-founder", name: "Foreign Founder", headline: "Founder"},
            %{scope: foreign_scope}
          )

        body = TaskResponseHelpers.response_text(create_response)
        [_, persona_id] = Regex.run(~r/\bid: `([^`]+)`/, body)
        {:ok, Map.put(context, :foreign_persona_id, persona_id)}
      end

      when_ "the PM links that persona using the active story's number", context do
        response =
          ToolLibrary.run(
            "link_persona_to_story",
            %{persona_id: context.foreign_persona_id, story_number: context.story.number},
            %{scope: context.scope}
          )

        # Observe the persistent outcome after the MCP action; then_ only asserts
        # the captured result and does not query the database.
        link_exists? =
          Fixtures.persona_story_link_exists?(context.foreign_persona_id, context.story.id)

        {:ok, Map.merge(context, %{response: response, link_exists?: link_exists?})}
      end

      then_ "the MCP response names a cross-project rejection", context do
        assert {:error, _} = context.response
        assert TaskResponseHelpers.response_text(context.response) =~ "Cross-project"
        {:ok, context}
      end

      then_ "no persona_stories row pairs the foreign persona with the active story", context do
        refute context.link_exists?
        {:ok, context}
      end
    end
  end
end
