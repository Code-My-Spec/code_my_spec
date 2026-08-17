defmodule CodeMySpecSpex.Story958.Criterion7939Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7939 — Assigning a story to a new epic moves it out of the old one.

  A story belongs to at most one epic, so a drop is a move, not an add.

  Surface: EpicsLive board (LiveView). `render_hook/3` stands in for the drag —
  it pushes the same `move_story` event Sortable does.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Assigning a story to a new epic moves it out of the old one" do
    scenario "The story belongs only to the new epic" do
      given_ "the story \"#{@title}\" belongs to epic \"Political Systems\"", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, story_response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              story:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute story_response.isError, "expected create_story to succeed"
        story_id = story_id!(story_response)

        epic_ids =
          Map.new(["Political Systems", "Stone Age"], fn name ->
            {:reply, response, _frame} =
              CreateEpic.execute(%{name: name, description: "#{name} work."}, frame)

            refute response.isError, "expected create_epic to succeed for #{name}"

            {name, epic_id!(response)}
          end)

        {:reply, assign_response, _frame} =
          AssignStoryToEpic.execute(
            %{story_id: story_id, epic_name: "Political Systems"},
            frame
          )

        refute assign_response.isError, "expected the story to start in Political Systems"

        {:ok, context |> Map.put(:story_id, story_id) |> Map.put(:epic_ids, epic_ids)}
      end

      when_ "the user drags it into epic \"Stone Age\"", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.id}/epics")

        render_hook(board, "move_story", %{
          "story_id" => context.story_id,
          "epic_id" => context.epic_ids["Stone Age"]
        })

        {:ok, context}
      end

      then_ "the story belongs only to \"Stone Age\"", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age")

        assert html =~ "Stone Age",
               "expected the Stone Age epic page to render, got: #{html}"

        assert html =~ @title,
               "expected the story to have moved into Stone Age, got: #{html}"

        {:ok, context}
      end

      and_ "\"Political Systems\" no longer lists it", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/political-systems")

        # Anchor: the page really rendered, so the refute below is meaningful.
        assert html =~ "Political Systems",
               "expected the Political Systems epic page to render, got: #{html}"

        refute html =~ @title,
               "expected the story to have left Political Systems, got: #{html}"

        {:ok, context}
      end
    end
  end

  defp story_id!(response) do
    body = response_text(response)

    captured!(
      Regex.run(~r/\(ID: (\d+)\)/, body),
      "could not read story id from response: #{body}"
    )
  end

  defp epic_id!(response) do
    body = response_text(response)

    captured!(
      Regex.run(~r/\(ID: ([0-9a-f-]{36})/, body),
      "could not read epic id from response: #{body}"
    )
  end

  # Two heads rather than a `case`: pattern matching in a function head is not
  # control flow, and it keeps the message the raise was building. A bare
  # `[_, id] = Regex.run(...)` would also remove the branch, but `Regex.run/2`
  # returns nil on no match — the MatchError would read "value: nil" and throw
  # away the haystack that says what went wrong.
  defp captured!([_, value], _message), do: value
  defp captured!(_no_match, message), do: raise(message)
end
