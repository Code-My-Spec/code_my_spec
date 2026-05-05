defmodule CodeMySpecSpex.Story686.Criterion5914Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5914 — Agent starts a Three Amigos session on a specific
  story. The MCP tool returns the Three Amigos protocol prompt scoped
  to that story.

  Surface: `start_three_amigos_session` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent starts a Three Amigos session on a story" do
    scenario "Tool returns the Three Amigos prompt scoped to the story" do
      given_ "a story exists in the active project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story for Three Amigos",
            description: "Will host a workshop session.",
            acceptance_criteria: []
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent calls start_three_amigos_session with the story id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartThreeAmigosSession.execute(
            %{story_id: to_string(context.story.id)},
            frame
          )

        refute response.isError,
               "expected start_three_amigos_session to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :session_response, response)}
      end

      then_ "the response is the Three Amigos prompt for that story", context do
        body = response_text(context.session_response)

        assert body =~ "Three Amigos",
               "expected Three Amigos framing in prompt, got: #{inspect(body)}"

        assert body =~ context.story.title,
               "expected prompt to reference the target story, got: #{inspect(body)}"

        assert body =~ ~r/add_rule|add_scenario|persona/i,
               "expected protocol tools mentioned in prompt, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
