defmodule CodeMySpecSpex.Story686.Criterion5907Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5907 — Agent creates a story, story appears in the active
  project's backlog.

  Surface: `create_story` and `list_story_titles` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent creates a story through the PM server" do
    scenario "Story appears in the active project's backlog" do
      when_ "the agent calls create_story with a title and description", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Driver onboarding",
          description: "As a driver, I want a guided sign-up so I can start.",
          acceptance_criteria: []
        }

        {:reply, response, _frame} = CreateStory.execute(params, frame)

        refute response.isError,
               "expected create_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :create_response, response)}
      end

      then_ "list_story_titles includes the new story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} = ListStoryTitles.execute(%{}, frame)
        body = response_text(list_response)

        assert body =~ "Driver onboarding",
               "expected new story to appear in list_story_titles, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
