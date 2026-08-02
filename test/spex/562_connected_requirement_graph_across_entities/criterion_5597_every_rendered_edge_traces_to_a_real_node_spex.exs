defmodule CodeMySpecSpex.Story562.Criterion5597Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5597 — Every edge in the rendered graph traces back to a
  prerequisites entry on its source node.

  The internal property "edges are not synthesized by string-matching
  code" is not directly observable from the surface. The strongest
  surface-level guarantee is structural integrity: every rendered
  edge has both endpoints present in the rendered node list — no
  edges pointing at non-existent nodes.

  If the future graph implementation chose to expose per-node
  prerequisite metadata in the rendered JSON, this spec should be
  expanded to assert per-edge that `e.target ∈ source.prerequisites`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Rendered graph has structural integrity" do
    scenario "every edge's source and target are present in the node list" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every edge's source and target appear in the node list",
            context do
        node_keys = MapSet.new(context.graph["nodes"], & &1["key"])

        dangling_edges =
          Enum.filter(context.graph["edges"], fn e ->
            not MapSet.member?(node_keys, e["source"]) or
              not MapSet.member?(node_keys, e["target"])
          end)

        assert dangling_edges == [],
               "expected every edge to point at real nodes, found dangling: #{inspect(Enum.map(dangling_edges, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end
    end
  end
end
