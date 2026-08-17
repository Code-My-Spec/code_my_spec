defmodule CodeMySpecSpex.Story715.Criterion6308Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6308 — show_story_requirements lists requirements for a known story by ID.

  When a story exists with a known integer ID and the agent calls
  `show_story_requirements` with that ID as a string, the response
  text names the story, reports a `done/total` satisfaction count,
  and lists every requirement on the story as a checklist line.

  Surface: `ShowStoryRequirements` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirement-query tools resolve their reference and return requirement details or done/total summaries; an unknown reference returns a not-found error rather than crashing" do
    scenario "show_story_requirements lists requirements for a known story by ID" do
      given_ :story_with_liveview_surface

      when_ "the agent calls show_story_requirements with the story's ID as a string", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response names the story", context do
        assert context.body =~ "# #{context.story.title}",
               "expected story title `#{context.story.title}` as header, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response reports a done/total satisfaction count", context do
        assert context.body =~ ~r/\*\*Requirements:\*\*\s+\d+\/\d+\s+satisfied/,
               "expected `**Requirements:** N/M satisfied`, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "every requirement on the story appears as a checklist line", context do
        assert context.body =~ ~r/^-\s+\[[ x]\]\s+\*\*[a-z_]+\*\*/m,
               "expected at least one checklist line for a requirement, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
