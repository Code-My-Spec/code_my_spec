defmodule CodeMySpecSpex.Story671.Criterion5635Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5635 — Disabling reviews keeps the parent context's
  implementation_file gated on real upstream work — concretely on
  the children's terminal requirements (tests_passing /
  test_spec_alignment) — and removes any incoming edge from a
  review node. The chain stays continuous; impl_file does not
  become vacuously actionable.

  Within the post-reduction graph, the immediate incoming edge to
  parent.impl_file is whichever child node has no longer path to
  parent.impl_file (typically tests_passing / test_spec_alignment).
  Spec_valid still gates impl_file transitively through the
  children's chains.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Disabling reviews keeps impl_file gated on the surviving child chain" do
    scenario "parent impl_file's incoming chain comes from real child work, never from review nodes" do
      given_ :context_with_three_children
      given_ :on_configuration_page

      when_ "the engineer disables require_reviews", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: true,
            require_reviews: false,
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

      then_ "parent implementation_file has no incoming edge from a review node",
            context do
        impl_key =
          GraphAssertions.node_key("component", context.parent_context.id, "implementation_file")

        review_incoming =
          context.graph
          |> GraphAssertions.edges_to(impl_key)
          |> Enum.filter(fn e ->
            String.ends_with?(e["source"], "_review_file") or
              String.ends_with?(e["source"], "_review_valid")
          end)

        assert review_incoming == [],
               "expected parent impl_file to have no incoming review edges, found: #{inspect(Enum.map(review_incoming, & &1["source"]))}"

        {:ok, context}
      end

      and_ "parent implementation_file is gated on real child work",
           context do
        impl_key =
          GraphAssertions.node_key("component", context.parent_context.id, "implementation_file")

        incoming = GraphAssertions.edges_to(context.graph, impl_key)

        assert incoming != [],
               "expected parent impl_file to have at least one incoming edge after splicing reviews"

        # Every incoming edge must come from a component-typed node
        # (a child's surviving terminal), not a story or project node.
        non_component =
          Enum.reject(incoming, fn e -> String.starts_with?(e["source"], "component_") end)

        assert non_component == [],
               "expected every incoming edge to parent impl_file to come from a child component, found foreign sources: #{inspect(Enum.map(non_component, & &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
