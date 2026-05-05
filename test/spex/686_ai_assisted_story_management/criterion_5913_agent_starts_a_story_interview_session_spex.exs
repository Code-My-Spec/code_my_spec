defmodule CodeMySpecSpex.Story686.Criterion5913Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5913 — Agent starts a story interview session on the active
  project. The MCP tool returns an interview prompt the agent will use
  to drive the PM conversation.

  Surface: `start_story_interview` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.StartStoryInterview

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent starts a story interview session" do
    scenario "Tool returns the PM-interview prompt for the active project" do
      when_ "the agent calls start_story_interview", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = StartStoryInterview.execute(%{}, frame)

        refute response.isError,
               "expected start_story_interview to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :session_response, response)}
      end

      then_ "the response is the story-interview prompt", context do
        body = response_text(context.session_response)

        assert body =~ "Product Manager",
               "expected interview prompt header, got: #{inspect(body)}"

        assert body =~ "produce a set of bare user stories",
               "expected the bare-user-stories instruction, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
