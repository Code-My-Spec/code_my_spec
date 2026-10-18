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

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @released "Flint knapping"
  @parked "Fire keeping"

  spex "Deleting an epic returns its stories to the unfiled column", criterion: 564 do
    scenario "Both stories survive, become unfiled, and keep their readiness" do
      given_ "epic \"Stone Age\" contains two stories, one released and one parked",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        epic_response =
          ToolLibrary.run(
            "create_epic",
            %{name: "Stone Age", description: "Earliest age."},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, epic_response), "expected create_epic to succeed"

        released = file_story(frame, @released, "Stone Age")
        _parked = file_story(frame, @parked, "Stone Age")

        update_response =
          ToolLibrary.run(
            "update_story",
            %{story_number: released, ready_for_dev: true},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, update_response), "expected the released story to be released"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:epic_id, epic_id!(epic_response))}
      end

      when_ "the user deletes the epic", context do
        {:ok, board, _html} = live(context.conn, "/app/projects/#{context.project.id}/epics")

        render_click(board, "delete", %{"id" => context.epic_id})

        {:ok, context}
      end

      then_ "both stories still exist and appear in the unfiled column", context do
        {:ok, _board, html} = live(context.conn, "/app/projects/#{context.project.id}/epics")

        refute html =~ "Stone Age",
               "expected the epic to be gone from the board, got: #{html}"

        # The board re-render agreeing is not enough: e7b8d597 found a case
        # where a LiveView's own render said the epic was gone (flash shown,
        # card removed) while the row survived on disk. `list_epics` reads
        # the same table through an entirely separate process (the MCP tool,
        # not the board's LiveView), so this independently confirms the
        # delete reached the database rather than trusting the same view
        # that reported success to also report absence correctly.
        epics_response =
          ToolLibrary.run(
            "list_epics",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        remaining = response_text(epics_response)

        refute remaining =~ context.epic_id,
               "expected the epic gone from list_epics (reads the table directly), got: #{remaining}"

        unfiled = unfiled_section(html)

        for title <- [@released, @parked] do
          assert unfiled =~ title,
                 "expected #{inspect(title)} back in the unfiled column, got: #{unfiled}"
        end

        {:ok, context}
      end

      and_ "each story keeps the readiness it had before the delete", context do
        response =
          ToolLibrary.run(
            "list_stories",
            %{ready_for_dev: true, limit: 100},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

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
    html
    |> String.split("unassigned-dropzone", parts: 2)
    |> unfiled_tail(html)
  end

  defp unfiled_tail([_, tail], _html), do: tail

  defp unfiled_tail(_no_split, html),
    do: raise("unfiled dropzone not found on the board: #{html}")

  defp file_story(frame, title, epic_name) do
    response =
      ToolLibrary.run(
        "create_story",
        %{title: title, story: "As a player, I want #{title} so that the age feels alive."},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response), "expected create_story to succeed for #{title}"

    story_number = story_number!(response)

    assign_response =
      ToolLibrary.run(
        "assign_story_to_epic",
        %{story_number: story_number, epic_name: epic_name},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, assign_response), "expected #{title} to be filed into #{epic_name}"

    story_number
  end

  defp story_number!(response) do
    body = response_text(response)

    ~r/^Story (\d+) created/
    |> Regex.run(body)
    |> captured!("could not read story number from response: #{body}")
    |> String.to_integer()
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
