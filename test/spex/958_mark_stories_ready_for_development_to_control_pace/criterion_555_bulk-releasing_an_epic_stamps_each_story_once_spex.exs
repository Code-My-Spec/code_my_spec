defmodule CodeMySpecSpex.Story958.Criterion7941Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7941 — Bulk-releasing an epic stamps each story once.

  This is the criterion that keeps epics organizational rather than
  executional: releasing an epic is a one-shot bulk edit of the stories that
  are in it at that moment, NOT a live cascade. A story filed into the epic
  afterwards is unaffected.

  Surface: EpicsLive.Show (LiveView) for the release; epic MCP tools to file
  the stories.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @story_count 10

  spex "Bulk-releasing an epic stamps each story once", criterion: 555 do
    scenario "Each story in the epic at release time becomes ready; later additions do not" do
      given_ "epic \"Stone Age\" contains ten stories that are not ready for development",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        epic_response =
          ToolLibrary.run(
            "create_epic",
            %{name: "Stone Age", description: "The earliest age of play."},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, epic_response), "expected create_epic to succeed"

        titles =
          for n <- 1..@story_count do
            title = "Stone age story #{n}"
            file_story(frame, title)
            title
          end

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_titles, titles)}
      end

      when_ "the user releases the epic's stories for development", context do
        {:ok, show_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age")

        show_live
        |> element("[data-test='bulk-release-epic']")
        |> render_click()

        {:ok, context}
      end

      then_ "each of those ten stories is individually ready for development", context do
        {:ok, _show_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age")

        for title <- context.story_titles do
          assert html =~ title,
                 "expected #{inspect(title)} to still be listed in the epic, got: #{html}"
        end

        assert ready_badges(html) == @story_count,
               "expected all #{@story_count} stories to be marked ready, " <>
                 "found #{ready_badges(html)}"

        {:ok, context}
      end

      and_ "a story filed into \"Stone Age\" afterwards is still not ready for development",
           context do
        late_title = "Stone age story added later"
        file_story(context.frame, late_title)

        {:ok, _show_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/epics/stone-age")

        assert html =~ late_title,
               "expected the late story to be in the epic, got: #{html}"

        assert ready_badges(html) == @story_count,
               "expected the late story NOT to be swept ready by the earlier bulk release — " <>
                 "expected #{@story_count} ready stories, found #{ready_badges(html)}"

        {:ok, context}
      end
    end
  end

  defp file_story(frame, title) do
    response =
      ToolLibrary.run(
        "create_story",
        %{
          title: title,
          story: "As a player, I want #{title} so that the stone age feels alive."
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response), "expected create_story to succeed for #{title}"

    assign_response =
      ToolLibrary.run(
        "assign_story_to_epic",
        %{story_number: story_number!(response), epic_name: "Stone Age"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, assign_response), "expected #{title} to be filed into the epic"

    :ok
  end

  defp ready_badges(html) do
    html |> String.split("data-test=\"story-ready\"") |> length() |> Kernel.-(1)
  end

  defp story_number!(response) do
    body = response_text(response)

    ~r/^Story (\d+) created/
    |> Regex.run(body)
    |> captured!("could not read story number from response: #{body}")
    |> String.to_integer()
  end

  # Two heads rather than a `case`: pattern matching in a function head is not
  # control flow, and it keeps the message the raise was building. A bare
  # `[_, id] = Regex.run(...)` would also remove the branch, but `Regex.run/2`
  # returns nil on no match — the MatchError would read "value: nil" and throw
  # away the haystack that says what went wrong.
  defp captured!([_, value], _message), do: value
  defp captured!(_no_match, message), do: raise(message)
end
