defmodule CodeMySpecSpex.Story562.Criterion5653Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5653 — A leaf surface (no children of its own) feeds
  bdd_specs_passing through its own last :self terminal. Exactly
  one incoming edge from the surface's tests_passing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Leaf surface terminal feeds bdd_specs_passing" do
    scenario "bdd_specs_passing has exactly one incoming edge — the surface's tests_passing" do
      given_ :story_with_liveview_surface

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_passing has exactly one incoming edge from the surface's tests_passing",
            context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        surface_terminal_key =
          GraphAssertions.node_key(
            "component",
            context.surface_liveview.id,
            "tests_passing"
          )

        incoming = GraphAssertions.edges_to(context.graph, passing_key)
        sources = Enum.map(incoming, & &1["source"])

        assert sources == [surface_terminal_key],
               "expected bdd_specs_passing to have exactly one incoming edge from #{surface_terminal_key}, got: #{inspect(sources)}"

        {:ok, context}
      end
    end
  end
end
