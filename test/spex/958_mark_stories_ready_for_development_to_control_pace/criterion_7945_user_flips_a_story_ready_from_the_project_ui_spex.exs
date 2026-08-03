defmodule CodeMySpecSpex.Story958.Criterion7945Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7945 — User flips a story ready from the project UI.

  Surface: StoryLive (LiveView).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "User flips a story ready from the project UI" do
    scenario "The story becomes ready for development" do
      given_ "the story \"#{@title}\" is not ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute response.isError, "expected create_story to succeed"

        {:ok, index_live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        assert html =~ "data-test=\"story-not-ready\"",
               "expected the story to start parked, got: #{html}"

        {:ok, Map.put(context, :index_live, index_live)}
      end

      when_ "the user marks it ready for development from the project UI", context do
        html =
          context.index_live
          |> element("[data-test='toggle-story-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, html)}
      end

      then_ "the story is ready for development", context do
        {:ok, _index_live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        # Anchor: the story is still on the page, so the marker assertions
        # below are about the flag rather than a missing row.
        assert html =~ @title,
               "expected the story to still be listed, got: #{html}"

        assert html =~ "data-test=\"story-ready\"",
               "expected the story to be marked ready for development, got: #{html}"

        refute html =~ "data-test=\"story-not-ready\"",
               "expected the parked marker to be gone, got: #{html}"

        {:ok, context}
      end
    end
  end
end
