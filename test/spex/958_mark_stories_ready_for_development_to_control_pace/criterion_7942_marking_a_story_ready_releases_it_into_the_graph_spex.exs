defmodule CodeMySpecSpex.Story958.Criterion7942Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7942 — Marking a story ready releases it into the graph.

  The load-bearing criterion of the story: readiness is what makes a story
  produce requirements at all.

  Surface: StoryLive (LiveView) to flip the flag, `show_story_requirements`
  MCP tool to observe the graph.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Marking a story ready releases it into the graph" do
    scenario "The graph serves requirements only after the story is released" do
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

        {:ok, context}
      end

      and_ "the development graph offers no requirements for it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: @title}, frame)

        body = response_text(response)

        refute body =~ "component_linked",
               "expected a parked story to produce no requirements, got: #{body}"

        {:ok, context}
      end

      when_ "the user marks it ready for development", context do
        {:ok, index_live, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.name}/stories")

        html =
          index_live
          |> element("[data-test='toggle-story-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, html)}
      end

      then_ "the development graph serves requirements for that story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: @title}, frame)

        body = response_text(response)

        refute response.isError,
               "expected show_story_requirements to succeed, got: #{inspect(response)}"

        assert body =~ "component_linked",
               "expected the released story to produce requirements, got: #{body}"

        {:ok, context}
      end
    end
  end
end
