defmodule CodeMySpecSpex.Story958.Criterion7958Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7958 — Deleting an epic returns its stories to the unfiled column.

  Epics are organizational, so deleting one must never destroy work. The FK
  is `ON DELETE SET NULL`: stories survive with `epic_id` cleared, which puts
  them back in the unfiled column with their readiness untouched.

  Surface: EpicsLive board (LiveView). The delete button sits behind a
  confirm dialog whose confirm action pushes `delete`, which is the event
  driven here.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStories
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @released "Flint knapping"
  @parked "Fire keeping"

  spex "Deleting an epic returns its stories to the unfiled column" do
    scenario "Both stories survive, become unfiled, and keep their readiness" do
      given_ "epic \"Stone Age\" contains two stories, one released and one parked",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, epic_response, _frame} =
          CreateEpic.execute(%{name: "Stone Age", description: "Earliest age."}, frame)

        refute epic_response.isError, "expected create_epic to succeed"

        released_id = file_story(frame, @released, "Stone Age")
        _parked_id = file_story(frame, @parked, "Stone Age")

        {:reply, update_response, _frame} =
          UpdateStory.execute(%{story_id: released_id, ready_for_dev: true}, frame)

        refute update_response.isError, "expected the released story to be released"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:epic_id, epic_id!(epic_response))}
      end

      when_ "the user deletes the epic", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.name}/epics")

        render_click(board, "delete", %{"id" => context.epic_id})

        {:ok, context}
      end

      then_ "both stories still exist and appear in the unfiled column", context do
        {:ok, _board, html} = live(context.conn, "/app/projects/#{context.project.name}/epics")

        refute html =~ "Stone Age",
               "expected the epic to be gone from the board, got: #{html}"

        unfiled = unfiled_section(html)

        for title <- [@released, @parked] do
          assert unfiled =~ title,
                 "expected #{inspect(title)} back in the unfiled column, got: #{unfiled}"
        end

        {:ok, context}
      end

      and_ "each story keeps the readiness it had before the delete", context do
        {:reply, response, _frame} =
          ListStories.execute(%{ready_for_dev: true, limit: 100}, context.frame)

        ready = response_text(response)

        assert ready =~ @released,
               "expected the released story to still be ready after the delete, got: #{ready}"

        refute ready =~ @parked,
               "expected the parked story to stay parked after the delete, got: #{ready}"

        {:ok, context}
      end
    end
  end

  # The board renders epics and unfiled stories in separate columns; scope the
  # membership assertions to the unfiled dropzone so a story still shown under
  # an epic cannot satisfy them.
  defp unfiled_section(html) do
    case String.split(html, "unassigned-dropzone", parts: 2) do
      [_, tail] -> tail
      _ -> raise "unfiled dropzone not found on the board: #{html}"
    end
  end

  defp file_story(frame, title, epic_name) do
    {:reply, response, _frame} =
      CreateStory.execute(
        %{title: title, story: "As a player, I want #{title} so that the age feels alive."},
        frame
      )

    refute response.isError, "expected create_story to succeed for #{title}"

    story_id = story_id!(response)

    {:reply, assign_response, _frame} =
      AssignStoryToEpic.execute(%{story_id: story_id, epic_name: epic_name}, frame)

    refute assign_response.isError, "expected #{title} to be filed into #{epic_name}"

    story_id
  end

  defp story_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end

  defp epic_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: ([0-9a-f-]{36})/, body) do
      [_, id] -> id
      _ -> raise "could not read epic id from response: #{body}"
    end
  end
end
