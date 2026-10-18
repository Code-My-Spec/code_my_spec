defmodule CodeMySpecSpex.Story686.Criterion7955Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7955 — Agent filters the backlog to stories not yet ready.

  This is how the PM agent finds parked work to release — the only route to
  stories the development graph deliberately hides.

  Surface: `create_story`, `update_story` and `list_stories` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @released "Released story"
  @parked "Parked story"

  spex "Agent filters the backlog to stories not yet ready", criterion: 387 do
    scenario "Only the not-ready stories come back" do
      given_ "the project has both ready and not-ready stories", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        released_response =
          ToolLibrary.run(
            "create_story",
            %{
              title: @released,
              description: "As a player, I want released work so that the queue moves."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, released_response),
               "expected create_story to succeed for the released story"

        update_response =
          ToolLibrary.run(
            "update_story",
            %{story_number: story_number!(released_response), ready_for_dev: true},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, update_response),
               "expected update_story to accept ready_for_dev, got: #{inspect(update_response)}"

        parked_response =
          ToolLibrary.run(
            "create_story",
            %{
              title: @parked,
              description: "As a player, I want parked work so that the backlog has depth."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, parked_response),
               "expected create_story to succeed for the parked story"

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent lists stories filtered to not ready for development", context do
        response =
          ToolLibrary.run(
            "list_stories",
            %{ready_for_dev: false},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected list_stories to accept a ready_for_dev filter, got: #{inspect(response)}"

        {:ok, Map.put(context, :list_body, response_text(response))}
      end

      then_ "only the not-ready stories are returned", context do
        body = context.list_body

        assert body =~ @parked,
               "expected the parked story in a not-ready listing, got: #{body}"

        refute body =~ @released,
               "expected the released story to be excluded from a not-ready listing, got: #{body}"

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
