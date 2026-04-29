defmodule CodeMySpecSpex.Story671.Criterion5636Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5636 — Disabling specs splices review_file to a sensible
  upstream OR makes it a root node with no incoming edges. In either
  case, no edge with review_file as target points at a removed spec
  node.

  In the context_graph, review_file (id 5) has prereq [4] (child
  spec_valid). With specs filtered, the chain walks back:
  4 → 3 (child spec_file) → 2 (parent spec_valid) → 1 (parent
  spec_file) → []. So review_file becomes a root.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Disabling specs leaves review_file with no spec-pointing incoming edge" do
    scenario "review_file has no incoming edge from any spec node (rewired or root)" do
      given_ :context_with_three_children
      given_ :on_configuration_page

      when_ "the engineer disables require_specs", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: false,
            require_reviews: true,
            require_unit_tests: true
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "the engineer renders the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "review_file (parent context) has no incoming edge from a spec node",
            context do
        review_file_key =
          GraphAssertions.node_key("component", context.parent_context.id, "review_file")

        # The node should still exist (reviews are required).
        assert GraphAssertions.find_node(
                 context.graph,
                 "component",
                 context.parent_context.id,
                 "review_file"
               ),
               "review_file should still appear when require_reviews is true"

        spec_pointing =
          context.graph
          |> GraphAssertions.edges_to(review_file_key)
          |> Enum.filter(fn e ->
            String.ends_with?(e["source"], "_spec_file") or
              String.ends_with?(e["source"], "_spec_valid")
          end)

        assert spec_pointing == [],
               "expected review_file to have no incoming edges from removed spec nodes, found: #{inspect(Enum.map(spec_pointing, & &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
