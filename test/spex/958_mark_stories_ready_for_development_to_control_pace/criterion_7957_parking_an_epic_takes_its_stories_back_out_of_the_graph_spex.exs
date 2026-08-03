defmodule CodeMySpecSpex.Story958.Criterion7957Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7957 — Parking an epic takes its stories back out of the graph.

  Park is the inverse of release and is scoped the same way: it stamps the
  stories in the epic and nothing else. The story outside the epic is the
  guard — a bulk park must not sweep the whole project.

  Surface: EpicsLive.Show (LiveView) to park; `list_stories` MCP tool to
  observe readiness.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStories
  alias CodeMySpec.McpServers.Stories.Tools.SetEpicStoriesReady
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @epic_titles ["Flint knapping", "Fire keeping", "Cave painting"]
  @outsider "Bronze smelting"

  spex "Parking an epic takes its stories back out of the graph" do
    scenario "The epic's stories are parked and an outside story is untouched" do
      given_ "epic \"Stone Age\" contains three stories that are ready for development",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, epic_response, _frame} =
          CreateEpic.execute(%{name: "Stone Age", description: "Earliest age."}, frame)

        refute epic_response.isError, "expected create_epic to succeed"

        for title <- @epic_titles, do: file_story(frame, title, "Stone Age")

        {:reply, release_response, _frame} =
          SetEpicStoriesReady.execute(
            %{epic_name: "Stone Age", ready_for_dev: true},
            frame
          )

        refute release_response.isError, "expected the epic's stories to start released"

        {:ok, Map.put(context, :frame, frame)}
      end

      and_ "a story outside the epic is ready for development", context do
        {:reply, response, _frame} =
          CreateStory.execute(
            %{title: @outsider, story: "As a player, I want bronze so that ages advance."},
            context.frame
          )

        refute response.isError, "expected create_story to succeed for the outsider"

        {:reply, update_response, _frame} =
          UpdateStory.execute(
            %{story_id: story_id!(response), ready_for_dev: true},
            context.frame
          )

        refute update_response.isError, "expected the outsider to be released"

        {:ok, context}
      end

      when_ "the user parks the epic's stories", context do
        {:ok, show_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age")

        show_live
        |> element("[data-test='bulk-park-epic']")
        |> render_click()

        {:ok, context}
      end

      then_ "none of the epic's stories is ready for development", context do
        {:reply, response, _frame} =
          ListStories.execute(%{ready_for_dev: true, limit: 100}, context.frame)

        body = response_text(response)

        for title <- @epic_titles do
          refute body =~ title,
                 "expected #{inspect(title)} to be parked, got: #{body}"
        end

        {:ok, Map.put(context, :ready_body, body)}
      end

      and_ "the story outside the epic is still ready for development", context do
        assert context.ready_body =~ @outsider,
               "expected the bulk park to leave stories outside the epic alone, " <>
                 "got: #{context.ready_body}"

        {:ok, context}
      end
    end
  end

  defp file_story(frame, title, epic_name) do
    {:reply, response, _frame} =
      CreateStory.execute(
        %{title: title, story: "As a player, I want #{title} so that the age feels alive."},
        frame
      )

    refute response.isError, "expected create_story to succeed for #{title}"

    {:reply, assign_response, _frame} =
      AssignStoryToEpic.execute(
        %{story_id: story_id!(response), epic_name: epic_name},
        frame
      )

    refute assign_response.isError, "expected #{title} to be filed into #{epic_name}"

    :ok
  end

  defp story_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end
end
