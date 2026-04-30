defmodule CodeMySpecSpex.Story562.Criterion5647Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5647 — Edges with no alternative path are preserved by
  transitive reduction. A linear chain (e.g., spec_file → spec_valid)
  has no longer route between its endpoints, so the direct edge is
  the only connection and must survive the reduction pass.

  This is the inverse of the shortcut-elision criteria — the rule
  must not over-fire and drop edges that have no longer path
  bypassing them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Linear chain edges survive when no longer path exists" do
    scenario "spec_file → spec_valid is preserved on the parent context and on a schema child" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent context's spec_file → spec_valid edge is present",
            context do
        from_key =
          GraphAssertions.node_key("component", context.parent_context.id, "spec_file")

        to_key =
          GraphAssertions.node_key("component", context.parent_context.id, "spec_valid")

        assert GraphAssertions.edge?(context.graph, from_key, to_key),
               "expected the parent context's spec_file → spec_valid edge to survive transitive reduction (no longer path bypasses it)"

        {:ok, context}
      end

      and_ "the schema child's spec_file → spec_valid edge is present",
           context do
        from_key =
          GraphAssertions.node_key("component", context.child_schema.id, "spec_file")

        to_key =
          GraphAssertions.node_key("component", context.child_schema.id, "spec_valid")

        assert GraphAssertions.edge?(context.graph, from_key, to_key),
               "expected the schema child's spec_file → spec_valid edge to survive transitive reduction"

        {:ok, context}
      end
    end
  end
end
