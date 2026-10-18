defmodule CodeMySpecSpex.Story686.Criterion7951Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7951 — Agent bulk-releases an epic's stories.

  Surface: epic MCP tools for the bulk edit, `list_stories` to observe.

  The epic tools live under the Stories MCP server — epics are story
  organization, not a domain of their own.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  @story_count 10

  spex "Agent bulk-releases an epic's stories", criterion: 385 do
    scenario "Every story in the epic becomes ready for development" do
      given_ "epic \"Stone Age\" contains ten stories that are not ready for development",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        epic_response =
          ToolLibrary.run(
            "create_epic",
            %{name: "Stone Age", description: "The earliest age of play."},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, epic_response),
               "expected create_epic to succeed, got: #{inspect(epic_response)}"

        titles =
          for n <- 1..@story_count do
            title = "Stone age story #{n}"

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

            assert match?({:ok, _}, assign_response),
                   "expected #{title} to be assigned to the epic, got: #{inspect(assign_response)}"

            title
          end

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_titles, titles)}
      end

      when_ "the agent marks the epic's stories ready for development", context do
        response =
          ToolLibrary.run(
            "set_epic_stories_ready",
            %{epic_name: "Stone Age", ready_for_dev: true},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected the epic bulk-release tool to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "each of those ten stories is ready for development", context do
        response =
          ToolLibrary.run(
            "list_stories",
            %{ready_for_dev: true},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        body = response_text(response)

        assert match?({:ok, _}, response),
               "expected list_stories to succeed, got: #{inspect(response)}"

        for title <- context.story_titles do
          assert body =~ title,
                 "expected #{inspect(title)} to be ready after the bulk release, got: #{body}"
        end

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
