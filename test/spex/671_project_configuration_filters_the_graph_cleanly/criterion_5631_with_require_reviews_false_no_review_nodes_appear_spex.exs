defmodule CodeMySpecSpex.Story671.Criterion5631Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5631 — With require_reviews false, no review_file or
  review_valid node appears in the graph for any context, and no
  rendered edge references a removed review node.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_reviews=false strips review nodes from the graph" do
    scenario "no review_file/review_valid nodes, no edge references a removed review node" do
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
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no review_file or review_valid component node appears", context do
        review_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "component" and
              n["attributes"]["name"] in ["review_file", "review_valid"]
          end)

        assert review_nodes == [],
               "expected no review_file/review_valid component nodes after disabling require_reviews, found: #{inspect(Enum.map(review_nodes, & &1["attributes"]["name"]))}"

        {:ok, context}
      end

      and_ "no rendered edge references a review node", context do
        review_endpoints =
          context.graph["edges"]
          |> Enum.flat_map(fn e -> [e["source"], e["target"]] end)
          |> Enum.filter(fn k ->
            String.ends_with?(k, "_review_file") or String.ends_with?(k, "_review_valid")
          end)

        assert review_endpoints == [],
               "expected no edge to reference a review_file or review_valid node, found: #{inspect(review_endpoints)}"

        {:ok, context}
      end
    end
  end
end
