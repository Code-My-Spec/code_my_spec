defmodule CodeMySpecSpex.Story671.Criterion5629Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5629 — With require_specs false, no spec_file or spec_valid
  node appears in the graph for any component.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_specs=false strips spec nodes from the graph" do
    scenario "no spec_file/spec_valid nodes for any component, no edge references a removed spec node" do
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

      then_ "no spec_file or spec_valid component node appears", context do
        spec_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "component" and
              n["attributes"]["name"] in ["spec_file", "spec_valid"]
          end)

        assert spec_nodes == [],
               "expected no spec_file/spec_valid component nodes after disabling require_specs, found: #{inspect(Enum.map(spec_nodes, & &1["attributes"]["name"]))}"

        {:ok, context}
      end

      and_ "no rendered edge references a spec node", context do
        spec_endpoints =
          context.graph["edges"]
          |> Enum.flat_map(fn e -> [e["source"], e["target"]] end)
          |> Enum.filter(fn k ->
            String.ends_with?(k, "_spec_file") or String.ends_with?(k, "_spec_valid")
          end)

        assert spec_endpoints == [],
               "expected no edge to reference a spec_file or spec_valid node, found: #{inspect(spec_endpoints)}"

        {:ok, context}
      end
    end
  end
end
