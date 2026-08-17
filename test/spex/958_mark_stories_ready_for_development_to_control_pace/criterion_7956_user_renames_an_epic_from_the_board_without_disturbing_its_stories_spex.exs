defmodule CodeMySpecSpex.Story958.Criterion7956Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7956 — User renames an epic from the board without disturbing its stories.

  Renaming re-derives the slug, so the real risk is losing the epic's
  membership on the way through. Surface: EpicsLive edit modal (LiveView).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @titles ["Flint knapping", "Fire keeping"]

  spex "User renames an epic from the board without disturbing its stories" do
    scenario "The epic is renamed and keeps its stories" do
      given_ "epic \"Stone Age\" contains two stories", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, epic_response, _frame} =
          CreateEpic.execute(%{name: "Stone Age", description: "Earliest age."}, frame)

        refute epic_response.isError, "expected create_epic to succeed"

        for title <- @titles, do: file_story(frame, title, "Stone Age")

        {:ok, context}
      end

      when_ "the user renames it to \"Neolithic\" from the board", context do
        {:ok, edit_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age/edit")

        edit_live
        |> form("[data-test='epic-form']",
          epic: %{name: "Neolithic", description: "Renamed age."}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the epic is listed as \"Neolithic\"", context do
        {:ok, _board, html} = live(context.conn, "/app/projects/#{context.project.id}/epics")

        assert html =~ "Neolithic",
               "expected the renamed epic on the board, got: #{html}"

        refute html =~ "Stone Age",
               "expected the old name to be gone, got: #{html}"

        {:ok, context}
      end

      and_ "both stories are still filed under it", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/neolithic")

        assert html =~ "Neolithic",
               "expected the renamed epic page to render at its new slug, got: #{html}"

        for title <- @titles do
          assert html =~ title,
                 "expected #{inspect(title)} to survive the rename, got: #{html}"
        end

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

    captured!(
      Regex.run(~r/\(ID: (\d+)\)/, body),
      "could not read story id from response: #{body}"
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
