defmodule CodeMySpecSpex.Story560.Criterion5155Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5155 — Cross-project link attempt is rejected at the library
  boundary.

  Criterion 5158 covers the contract-level rejection at the MCP tool surface
  (`LinkPersonaToStory` returning a cross-project error). This spec covers
  the library-boundary angle: the MCP rejection message makes it explicit
  that the project does not match, not just that the link failed.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "cross-project link attempt" do
    scenario "MCP response explicitly names the project boundary in its rejection" do
      given_ :persona_exists

      given_ "a story exists on a different project (same account)", context do
        foreign_project =
          Fixtures.project_fixture(context.scope, %{
            name: "Sibling project",
            module_name: "SiblingProject"
          })

        foreign_scope = %{context.scope | active_project: foreign_project, active_project_id: foreign_project.id}

        story =
          StoryHelpers.create_story(foreign_scope,
            title: "Foreign story",
            description: "Lives on a different project.",
            acceptance_criteria: ["Cross-project links are rejected"]
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

      then_ "the rejection message explicitly names the project boundary", context do
        body = response_text(context.response)

        assert body =~ ~r/project/i,
               "expected rejection to cite the project boundary, got #{inspect(context.response)}"

        assert body =~ ~r/reject|does not belong|cross-project/i,
               "expected an explicit rejection"

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
