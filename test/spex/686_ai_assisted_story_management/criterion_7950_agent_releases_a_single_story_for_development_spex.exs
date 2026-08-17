defmodule CodeMySpecSpex.Story686.Criterion7950Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7950 — Agent releases a single story for development.

  Surface: `update_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Agent releases a single story for development" do
    scenario "The story becomes ready for development" do
      given_ "the story \"#{@title}\" is not ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute response.isError, "expected create_story to succeed"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_id, story_id!(response))}
      end

      when_ "the agent marks it ready for development", context do
        {:reply, response, _frame} =
          UpdateStory.execute(
            %{story_id: context.story_id, ready_for_dev: true},
            context.frame
          )

        refute response.isError,
               "expected update_story to accept ready_for_dev, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "the story is ready for development", context do
        {:reply, response, _frame} =
          GetStory.execute(%{story_id: context.story_id}, context.frame)

        body = response_text(response)

        assert body =~ @title,
               "expected the story to still be readable, got: #{body}"

        assert body =~ "Ready for development: true",
               "expected the story to report itself ready for development, got: #{body}"

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
