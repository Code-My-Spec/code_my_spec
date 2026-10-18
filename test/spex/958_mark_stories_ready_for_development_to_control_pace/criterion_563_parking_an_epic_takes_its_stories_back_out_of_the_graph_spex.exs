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

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @epic_titles ["Flint knapping", "Fire keeping", "Cave painting"]
  @outsider "Bronze smelting"

  spex "Parking an epic takes its stories back out of the graph", criterion: 563 do
    scenario "The epic's stories are parked and an outside story is untouched" do
      given_ "epic \"Stone Age\" contains three stories that are ready for development",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        epic_response =
          ToolLibrary.run(
            "create_epic",
            %{name: "Stone Age", description: "Earliest age."},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, epic_response), "expected create_epic to succeed"

        for title <- @epic_titles, do: file_story(frame, title, "Stone Age")

        release_response =
          ToolLibrary.run(
            "set_epic_stories_ready",
            %{epic_name: "Stone Age", ready_for_dev: true},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, release_response), "expected the epic's stories to start released"

        {:ok, Map.put(context, :frame, frame)}
      end

      and_ "a story outside the epic is ready for development", context do
        response =
          ToolLibrary.run(
            "create_story",
            %{title: @outsider, story: "As a player, I want bronze so that ages advance."},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), "expected create_story to succeed for the outsider"

        update_response =
          ToolLibrary.run(
            "update_story",
            %{story_number: story_number!(response), ready_for_dev: true},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, update_response), "expected the outsider to be released"

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
        response =
          ToolLibrary.run(
            "list_stories",
            %{ready_for_dev: true, limit: 100},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

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
    response =
      ToolLibrary.run(
        "create_story",
        %{title: title, story: "As a player, I want #{title} so that the age feels alive."},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response), "expected create_story to succeed for #{title}"

    assign_response =
      ToolLibrary.run(
        "assign_story_to_epic",
        %{story_number: story_number!(response), epic_name: epic_name},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, assign_response), "expected #{title} to be filed into #{epic_name}"

    :ok
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
