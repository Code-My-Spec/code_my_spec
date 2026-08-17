defmodule CodeMySpecSpex.Story562.Criterion5649Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5649 — When the surface has a single cross-context
  dependency, the story's `bdd_specs_exist` outgoing edge lands on
  the dep's first requirement, not the surface's. The longer path
  through the dep chain subsumes a direct kickoff edge to the
  surface, and transitive reduction drops it.

  This is the visible payoff: the rendered chain follows the order
  of work — bdd_specs_exist → dep → surface → bdd_specs_passing —
  rather than two parallel kickoff edges (story → surface and
  dep → surface) that hide which one comes first.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Story kickoff resolves to the dep when the surface depends on it" do
    scenario "bdd_specs_exist's outgoing edge lands on the dep's first req, not the surface's" do
      given_ :story_with_liveview_surface

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_exist has an outgoing edge to the dep's first requirement",
            context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        dep_first_key =
          GraphAssertions.node_key("component", context.dep_context.id, "spec_file")

        assert GraphAssertions.edge?(context.graph, bdd_exist_key, dep_first_key),
               "expected bdd_specs_exist to kickoff at the dep's first requirement (#{dep_first_key})"

        {:ok, context}
      end

      and_ "bdd_specs_exist has no direct outgoing edge to the surface",
           context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        surface_first_key =
          GraphAssertions.node_key("component", context.surface_liveview.id, "spec_file")

        refute GraphAssertions.edge?(context.graph, bdd_exist_key, surface_first_key),
               "expected the direct bdd_specs_exist → surface edge to be subsumed by the dep chain and removed by transitive reduction"

        {:ok, context}
      end
    end
  end
end
