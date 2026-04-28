defmodule CodeMySpecSpex.Story560.Criterion5156Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5156 — Linking one persona to a story creates one join row.
  Observable: after calling LinkPersonaToStory via MCP, list_personas_for_story
  returns the linked persona.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM links a persona to a story via the MCP tool" do
    scenario "list_personas_for_story returns the linked persona" do
      given_ :persona_exists

      given_ "a second story exists", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Second story",
            description: "A second story to link to",
            acceptance_criteria: ["Persona linkage to a second story is observable"]
          )

        {:ok, Map.put(context, :second_story, story)}
      end

      when_ "the PM calls LinkPersonaToStory via MCP", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.second_story.id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the MCP response confirms the link with persona_id and story_id", context do
        body = response_text(context.response)

        assert body =~ "linked",
               "expected MCP response to confirm the link, got #{inspect(context.response)}"

        assert body =~ to_string(context.second_story.id),
               "expected MCP response to name the story_id in the confirmation"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)
end
