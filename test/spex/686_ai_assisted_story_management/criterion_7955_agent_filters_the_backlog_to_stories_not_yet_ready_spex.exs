defmodule CodeMySpecSpex.Story686.Criterion7955Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7955 — Agent filters the backlog to stories not yet ready.

  This is how the PM agent finds parked work to release — the only route to
  stories the development graph deliberately hides.

  Surface: `create_story`, `update_story` and `list_stories` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStories
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @released "Released story"
  @parked "Parked story"

  spex "Agent filters the backlog to stories not yet ready" do
    scenario "Only the not-ready stories come back" do
      given_ "the project has both ready and not-ready stories", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, released_response, _frame} =
          CreateStory.execute(
            %{
              title: @released,
              description: "As a player, I want released work so that the queue moves."
            },
            frame
          )

        refute released_response.isError,
               "expected create_story to succeed for the released story"

        {:reply, update_response, _frame} =
          UpdateStory.execute(
            %{story_id: story_id!(released_response), ready_for_dev: true},
            frame
          )

        refute update_response.isError,
               "expected update_story to accept ready_for_dev, got: #{inspect(update_response)}"

        {:reply, parked_response, _frame} =
          CreateStory.execute(
            %{
              title: @parked,
              description: "As a player, I want parked work so that the backlog has depth."
            },
            frame
          )

        refute parked_response.isError, "expected create_story to succeed for the parked story"

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent lists stories filtered to not ready for development", context do
        {:reply, response, _frame} =
          ListStories.execute(%{ready_for_dev: false}, context.frame)

        refute response.isError,
               "expected list_stories to accept a ready_for_dev filter, got: #{inspect(response)}"

        {:ok, Map.put(context, :list_body, response_text(response))}
      end

      then_ "only the not-ready stories are returned", context do
        body = context.list_body

        assert body =~ @parked,
               "expected the parked story in a not-ready listing, got: #{body}"

        refute body =~ @released,
               "expected the released story to be excluded from a not-ready listing, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses carry record ids in the text footer.
  defp story_id!(response) do
    response |> response_text() |> story_id_from()
  end

  defp story_id_from(body), do: story_id_match(Regex.run(~r/\(ID: (\d+)\)/, body), body)

  defp story_id_match([_, id], _body), do: id

  defp story_id_match(_no_match, body),
    do: raise("could not read story id from response: #{body}")
end
