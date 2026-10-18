defmodule CodeMySpecSpex.Story686.Criterion7950Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7950 — Agent releases a single story for development.

  Surface: `update_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Agent releases a single story for development", criterion: 384 do
    scenario "The story becomes ready for development" do
      given_ "the story \"#{@title}\" is not ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "create_story",
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), "expected create_story to succeed"

        {:ok,
         context |> Map.put(:frame, frame) |> Map.put(:story_number, story_number!(response))}
      end

      when_ "the agent marks it ready for development", context do
        response =
          ToolLibrary.run(
            "update_story",
            %{story_number: context.story_number, ready_for_dev: true},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected update_story to accept ready_for_dev, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "the story is ready for development", context do
        response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story_number},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        body = response_text(response)

        assert body =~ @title,
               "expected the story to still be readable, got: #{body}"

        assert body =~ "Ready for development: true",
               "expected the story to report itself ready for development, got: #{body}"

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
