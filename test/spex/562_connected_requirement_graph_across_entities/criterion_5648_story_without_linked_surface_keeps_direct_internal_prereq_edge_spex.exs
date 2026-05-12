defmodule CodeMySpecSpex.Story562.Criterion5648Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5648 — A story with no linked surface component keeps
  the direct internal `bdd_specs_exist → bdd_specs_passing` edge.
  Without a surface, there's no longer path between the two story
  nodes for transitive reduction to find, so the direct edge must
  survive.

  Surface: requirements graph LiveView at
  /projects/:name/requirements/graph?preload=true.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecLocalWeb.Endpoint

  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Direct edge survives on a story with no linked surface" do
    scenario "bdd_specs_exist → bdd_specs_passing is preserved when the story has no component" do
      given_ "a story exists with no linked surface component", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Surfaceless story",
            description: "A story with no surface; the prereq edge between its terminal nodes has no longer path to find.",
            acceptance_criteria: ["Some acceptance"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/projects/#{context.project.name}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the story's bdd_specs_exist → bdd_specs_passing edge is present", context do
        from_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        to_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        assert GraphAssertions.edge?(context.graph, from_key, to_key),
               "expected the direct bdd_specs_exist → bdd_specs_passing edge to survive transitive reduction on a story with no linked surface (no alternative path exists to bypass it)"

        {:ok, context}
      end
    end
  end
end
