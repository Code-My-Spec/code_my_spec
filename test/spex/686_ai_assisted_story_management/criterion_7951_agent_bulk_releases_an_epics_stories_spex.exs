defmodule CodeMySpecSpex.Story686.Criterion7951Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7951 — Agent bulk-releases an epic's stories.

  Surface: epic MCP tools for the bulk edit, `list_stories` to observe.

  The epic tools live under the Stories MCP server — epics are story
  organization, not a domain of their own.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStories
  alias CodeMySpec.McpServers.Stories.Tools.SetEpicStoriesReady

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @story_count 10

  spex "Agent bulk-releases an epic's stories" do
    scenario "Every story in the epic becomes ready for development" do
      given_ "epic \"Stone Age\" contains ten stories that are not ready for development",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, epic_response, _frame} =
          CreateEpic.execute(
            %{name: "Stone Age", description: "The earliest age of play."},
            frame
          )

        refute epic_response.isError,
               "expected create_epic to succeed, got: #{inspect(epic_response)}"

        titles =
          for n <- 1..@story_count do
            title = "Stone age story #{n}"

            {:reply, response, _frame} =
              CreateStory.execute(
                %{
                  title: title,
                  story: "As a player, I want #{title} so that the stone age feels alive."
                },
                frame
              )

            refute response.isError, "expected create_story to succeed for #{title}"

            {:reply, assign_response, _frame} =
              AssignStoryToEpic.execute(
                %{story_id: story_id!(response), epic_name: "Stone Age"},
                frame
              )

            refute assign_response.isError,
                   "expected #{title} to be assigned to the epic, got: #{inspect(assign_response)}"

            title
          end

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_titles, titles)}
      end

      when_ "the agent marks the epic's stories ready for development", context do
        {:reply, response, _frame} =
          SetEpicStoriesReady.execute(
            %{epic_name: "Stone Age", ready_for_dev: true},
            context.frame
          )

        refute response.isError,
               "expected the epic bulk-release tool to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "each of those ten stories is ready for development", context do
        {:reply, response, _frame} =
          ListStories.execute(%{ready_for_dev: true}, context.frame)

        body = response_text(response)

        refute response.isError, "expected list_stories to succeed, got: #{inspect(response)}"

        for title <- context.story_titles do
          assert body =~ title,
                 "expected #{inspect(title)} to be ready after the bulk release, got: #{body}"
        end

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
