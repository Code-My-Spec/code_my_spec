defmodule CodeMySpecSpex.Story958.Criterion7938Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7938 — User groups loose stories into a named epic.

  Surface: EpicsLive board (LiveView). Filing a story is a drag between the
  board's two columns; Sortable pushes `move_story` from the receiving list,
  which is what `render_hook/3` stands in for here — LiveViewTest cannot
  dispatch drag events.

  Stories are seeded through the `create_story` MCP tool — a real app
  surface — rather than fixtures.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @titles ["Gods grant boons", "Temples accrue favor"]

  spex "User groups loose stories into a named epic" do
    scenario "The epic exists with those stories as its members" do
      given_ "the project has stories that belong to no epic", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        story_ids =
          for title <- @titles do
            {:reply, response, _frame} =
              CreateStory.execute(
                %{
                  title: title,
                  story: "As a player, I want #{title} so that worship matters."
                },
                frame
              )

            refute response.isError, "expected create_story to succeed for #{title}"

            story_id!(response)
          end

        {:ok, Map.put(context, :story_ids, story_ids)}
      end

      when_ "the user creates an epic named \"Gods and Religion\"", context do
        {:ok, new_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/new")

        new_live
        |> form("[data-test='epic-form']",
          epic: %{
            name: "Gods and Religion",
            description: "Everything about deities and worship."
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "drags those stories into it", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.id}/epics")

        epic_id = epic_id_on_board!(board)

        for story_id <- context.story_ids do
          render_hook(board, "move_story", %{"story_id" => story_id, "epic_id" => epic_id})
        end

        {:ok, context}
      end

      then_ "the epic lists those stories as its members", context do
        {:ok, _epic_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/gods-and-religion")

        assert html =~ "Gods and Religion",
               "expected the epic page to render, got: #{html}"

        for title <- @titles do
          assert html =~ title,
                 "expected story #{inspect(title)} to belong to the epic, got: #{html}"
        end

        {:ok, context}
      end
    end
  end

  # The board renders one dropzone per epic, carrying the epic's id.
  defp epic_id_on_board!(board) do
    html = render(board)

    case Regex.run(~r/data-epic-id="([0-9a-f-]{36})"/, html) do
      [_, id] -> id
      _ -> raise "no epic dropzone found on the board: #{html}"
    end
  end

  defp story_id!(response) do
    body = CodeMySpecSpex.TaskResponseHelpers.response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end
end
