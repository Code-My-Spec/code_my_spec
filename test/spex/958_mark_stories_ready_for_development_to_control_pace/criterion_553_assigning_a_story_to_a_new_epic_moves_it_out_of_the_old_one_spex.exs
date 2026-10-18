defmodule CodeMySpecSpex.Story958.Criterion7939Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7939 — Assigning a story to a new epic moves it out of the old one.

  A story belongs to at most one epic, so a drop is a move, not an add.

  Surface: EpicsLive board (LiveView). `render_hook/3` stands in for the drag —
  it pushes the same `move_story` event Sortable does.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Stories

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Assigning a story to a new epic moves it out of the old one", criterion: 553 do
    scenario "The story belongs only to the new epic" do
      given_ ~s(the story "#{@title}" belongs to epic "Political Systems"), context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        story_response =
          ToolLibrary.run(
            "create_story",
            %{
              title: @title,
              story:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, story_response), "expected create_story to succeed"
        story_number = story_number!(story_response)

        epic_ids =
          Map.new(["Political Systems", "Stone Age"], fn name ->
            response =
              ToolLibrary.run(
                "create_epic",
                %{name: name, description: "#{name} work."},
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, response), "expected create_epic to succeed for #{name}"

            {name, epic_id!(response)}
          end)

        assign_response =
          ToolLibrary.run(
            "assign_story_to_epic",
            %{story_number: story_number, epic_name: "Political Systems"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, assign_response),
               "expected the story to start in Political Systems"

        story_id = Stories.get_story_by_number(context.scope, story_number).id

        {:ok,
         context
         |> Map.put(:story_number, story_number)
         |> Map.put(:story_id, story_id)
         |> Map.put(:epic_ids, epic_ids)}
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
