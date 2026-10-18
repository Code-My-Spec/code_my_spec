defmodule CodeMySpecSpex.Story686.Criterion5913Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5913 — Agent starts a story interview session on the active
  project. The MCP tool returns an interview prompt the agent will use
  to drive the PM conversation.

  Surface: `start_story_interview` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent starts a story interview session", criterion: 376 do
    scenario "Tool returns the PM-interview prompt for the active project" do
      when_ "the agent calls start_story_interview", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "start_story_interview",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected start_story_interview to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :session_response, response)}
      end

      then_ "the response is the story-interview prompt", context do
        body = response_text(context.session_response)

        assert body =~ "Product Manager",
               "expected interview prompt header, got: #{inspect(body)}"

        assert body =~ ~r/produce a set of\s+bare user stories/,
               "expected the bare-user-stories instruction, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
