defmodule CodeMySpecSpex.Story686.Criterion5908Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5908 — Agent updates a story's title and description, changes
  are reflected on next read.

  Surface: `update_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent updates a story" do
    scenario "Updated title and description are visible on next read" do
      given_ "a story exists in the active project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Original title",
            description: "Original description.",
            acceptance_criteria: []
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent calls update_story with a new title and description", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          story_id: to_string(context.story.id),
          title: "Renamed title",
          description: "Revised description."
        }

        {:reply, response, _frame} = UpdateStory.execute(params, frame)

        refute response.isError,
               "expected update_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :update_response, response)}
      end

      then_ "get_story returns the new title and description", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetStory.execute(%{story_id: to_string(context.story.id)}, frame)

        body = response_text(get_response)

        assert body =~ "Renamed title",
               "expected updated title in get_story output, got: #{inspect(body)}"

        assert body =~ "Revised description",
               "expected updated description in get_story output, got: #{inspect(body)}"

        refute body =~ "Original title",
               "expected old title to be replaced, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
