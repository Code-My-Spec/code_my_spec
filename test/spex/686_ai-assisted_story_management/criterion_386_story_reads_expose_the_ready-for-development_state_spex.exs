defmodule CodeMySpecSpex.Story686.Criterion7954Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7954 — Story reads expose the ready-for-development state.

  Writing the flag is useless to an agent that cannot read it back.

  Surface: `create_story`, `update_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Story reads expose the ready-for-development state", criterion: 386 do
    scenario "A released story reports itself as ready" do
      given_ "the story \"#{@title}\" is ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        create_response =
          ToolLibrary.run(
            "create_story",
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, create_response), "expected create_story to succeed"

        story_number = story_number!(create_response)

        update_response =
          ToolLibrary.run(
            "update_story",
            %{story_number: story_number, ready_for_dev: true},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, update_response),
               "expected update_story to accept ready_for_dev, got: #{inspect(update_response)}"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_number, story_number)}
      end

      when_ "the agent reads that story", context do
        response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story_number},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected get_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :story_body, response_text(response))}
      end

      then_ "the response shows that it is ready for development", context do
        body = context.story_body

        assert body =~ @title,
               "expected the story to be readable, got: #{body}"

        assert body =~ "Ready for development: true",
               "expected the read to surface the ready-for-development state, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses name the story by number.
  defp story_number!(response) do
    response |> response_text() |> story_number_from()
  end

  defp story_number_from(body),
    do: story_number_match(Regex.run(~r/^Story (\d+) (?:created|updated)/, body), body)

  defp story_number_match([_, n], _body), do: String.to_integer(n)

  defp story_number_match(_no_match, body),
    do: raise("could not read story number from response: #{body}")
end
