defmodule CodeMySpecSpex.Story686.Criterion7954Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7954 — Story reads expose the ready-for-development state.

  Writing the flag is useless to an agent that cannot read it back.

  Surface: `create_story`, `update_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Story reads expose the ready-for-development state" do
    scenario "A released story reports itself as ready" do
      given_ "the story \"#{@title}\" is ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, create_response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute create_response.isError, "expected create_story to succeed"

        story_id = story_id!(create_response)

        {:reply, update_response, _frame} =
          UpdateStory.execute(%{story_id: story_id, ready_for_dev: true}, frame)

        refute update_response.isError,
               "expected update_story to accept ready_for_dev, got: #{inspect(update_response)}"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_id, story_id)}
      end

      when_ "the agent reads that story", context do
        {:reply, response, _frame} =
          GetStory.execute(%{story_id: context.story_id}, context.frame)

        refute response.isError, "expected get_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :story_body, response_text(response))}
      end

      then_ "the response shows that it is ready for development", context do
        body = context.story_body

        assert body =~ @title,
               "expected the story to be readable, got: #{body}"

        assert body =~ "Ready for development: true",
               "expected the read to surface the ready-for-development state, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses carry record ids in the text footer.
  defp story_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end
end
