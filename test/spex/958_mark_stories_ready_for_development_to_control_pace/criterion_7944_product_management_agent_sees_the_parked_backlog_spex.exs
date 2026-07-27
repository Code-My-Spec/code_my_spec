defmodule CodeMySpecSpex.Story958.Criterion7944Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7944 — Product management agent sees the parked backlog.

  Parked stories are invisible to the development graph but must stay
  reachable through the backlog tools — otherwise the PM can never find
  them to release them.

  Surface: `list_stories` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStories

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Product management agent sees the parked backlog" do
    scenario "A parked story is returned by the backlog listing" do
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

        {:ok, context}
      end

      when_ "the product management agent lists the backlog", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListStories.execute(%{ready_for_dev: false}, frame)

        refute response.isError,
               "expected list_stories to accept a ready_for_dev filter, got: #{inspect(response)}"

        {:ok, Map.put(context, :list_response, response)}
      end

      then_ "it sees that story", context do
        body = response_text(context.list_response)

        assert body =~ @title,
               "expected the parked story to be reachable through the backlog listing, got: #{body}"

        {:ok, context}
      end
    end
  end
end
