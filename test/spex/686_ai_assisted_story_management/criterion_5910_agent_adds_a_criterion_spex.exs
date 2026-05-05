defmodule CodeMySpecSpex.Story686.Criterion5910Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5910 — Agent adds a criterion, criterion appears on the
  story.

  Surface: `add_criterion` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent adds an acceptance criterion to a story" do
    scenario "Criterion is visible on the story after the call" do
      given_ "a story exists with no criteria", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story needing criteria",
            description: "Will receive an acceptance criterion.",
            acceptance_criteria: []
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent calls add_criterion with a description", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          story_id: to_string(context.story.id),
          description: "Driver completes the welcome screen"
        }

        {:reply, response, _frame} = AddCriterion.execute(params, frame)

        refute response.isError,
               "expected add_criterion to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "get_story shows the new criterion", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetStory.execute(%{story_id: to_string(context.story.id)}, frame)

        body = response_text(get_response)

        assert body =~ "Driver completes the welcome screen",
               "expected new criterion in get_story output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
