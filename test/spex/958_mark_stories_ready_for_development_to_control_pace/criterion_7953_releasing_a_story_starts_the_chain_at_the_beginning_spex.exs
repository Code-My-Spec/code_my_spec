defmodule CodeMySpecSpex.Story958.Criterion7953Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7953 — Releasing a story starts the chain at the beginning.

  Readiness adds a gate in front of the existing chain; it does not replace
  or skip any step of it. A released story starts at `component_linked`, and
  Three Amigos still gates BDD specs exactly as before.

  Surface: StoryLive (LiveView) to release, `show_story_requirements` MCP
  tool to observe the chain.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Releasing a story starts the chain at the beginning" do
    scenario "The chain begins at component_linked and Three Amigos still gates BDD specs" do
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

      when_ "the user marks it ready for development", context do
        {:ok, index_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        html =
          index_live
          |> element("[data-test='toggle-story-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, html)}
      end

      then_ "its first offered requirement is a linked surface component", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: @title}, frame)

        body = response_text(response)

        refute response.isError,
               "expected show_story_requirements to succeed, got: #{inspect(response)}"

        assert body =~ "component_linked",
               "expected the released story's chain to begin at component_linked, got: #{body}"

        {:ok, Map.put(context, :requirements_body, body)}
      end

      and_ "Three Amigos is still required before any BDD specs are written for it", context do
        body = context.requirements_body

        assert body =~ "three_amigos_complete",
               "expected the Three Amigos gate to survive the new ready gate, got: #{body}"

        assert body =~ "bdd_specs_exist",
               "expected bdd_specs_exist to still be in the chain, got: #{body}"

        refute body =~ "[x] **bdd_specs_exist**",
               "expected BDD specs to remain unsatisfied while Three Amigos is incomplete, " <>
                 "got: #{body}"

        {:ok, context}
      end
    end
  end
end
