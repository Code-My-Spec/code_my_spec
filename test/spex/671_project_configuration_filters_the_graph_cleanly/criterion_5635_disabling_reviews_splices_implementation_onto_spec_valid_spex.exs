defmodule CodeMySpecSpex.Story671.Criterion5635Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5635 — Disabling reviews splices implementation_file's
  prereq onto spec_valid (the surviving upstream). The dependency
  chain stays continuous; no edge between implementation_file and
  any review node remains.

  This is the splice discriminator for the review category. Today
  filtering simply drops review-targeting edges, so implementation_file
  loses its review prereq with nothing wired in its place. The fix
  rewires impl_file's incoming chain through to spec_valid.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Disabling reviews splices impl_file onto spec_valid" do
    scenario "parent impl_file's incoming chain reaches spec_valid; no review edge remains" do
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

      and_ "parent implementation_file resolves to a spec_valid upstream",
           context do
        impl_key =
          GraphAssertions.node_key("component", context.parent_context.id, "implementation_file")

        spec_valid_incoming =
          context.graph
          |> GraphAssertions.edges_to(impl_key)
          |> Enum.filter(fn e -> String.ends_with?(e["source"], "_spec_valid") end)

        assert spec_valid_incoming != [],
               "expected parent impl_file to have at least one incoming edge from a spec_valid node after splicing reviews; got incoming sources: #{inspect(GraphAssertions.edges_to(context.graph, impl_key) |> Enum.map(& &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
