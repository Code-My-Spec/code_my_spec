defmodule CodeMySpecSpex.Story983.Criterion8157Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8157 — A freshly released story starts with its specs not ready.

  Rule: a story enters development with its specs not ready.

  `specs_ready` is the latch behind the `bdd_specs_passing` requirement.
  A story that has never been through the chain has never earned a green
  spex run, so the node must render unsatisfied the moment the story
  enters the graph.

  Surface: `create_story` / `set_story_component` MCP tools to author the
  story, StoryLive (LiveView) to release it, `show_story_requirements`
  MCP tool to observe the graph.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "A story enters development with its specs not ready" do
    scenario "A freshly released story starts with its specs not ready" do
      given_ :synced_context_component

      given_ "the story \"#{@title}\" has never been through the development chain",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: @title,
            description:
              "As the game world, I want each player to sit in one age so that age gaps drive politics.",
            acceptance_criteria: ["Each player sits in exactly one age"],
            ready_for_dev: false
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the user releases it for development", context do
        {:ok, index_live, _html} =
          live(context.conn, ~p"/projects/#{context.project.name}/stories")

        html =
          index_live
          |> element("[data-test='toggle-story-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, html)}
      end

      then_ "the story's specs are not ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: @title}, frame)

        body = response_text(response)

        refute response.isError,
               "expected show_story_requirements to succeed, got: #{inspect(response)}"

        # Anchor: the released story really is producing requirements, so
        # the assertion below is about the latch and not an empty graph.
        assert body =~ "component_linked",
               "expected the released story to produce requirements, got: #{body}"

        assert body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "expected bdd_specs_passing to be unsatisfied on a story that has never gone green, got: #{body}"

        {:ok, context}
      end
    end
  end
end
