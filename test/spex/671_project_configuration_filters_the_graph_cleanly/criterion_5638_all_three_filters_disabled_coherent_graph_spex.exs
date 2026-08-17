defmodule CodeMySpecSpex.Story671.Criterion5638Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5638 — With require_specs, require_reviews, AND
  require_unit_tests all set to false, the graph is still coherent:
  every edge endpoint resolves to a rendered node, no edge or node
  references any spec/review/test artifact, and the only remaining
  component nodes are implementation_file (plus non-filtered
  project/story nodes).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  @filtered_component_names ~w(
    spec_file
    spec_valid
    review_file
    review_valid
    test_file
    test_spec_alignment
    tests_passing
  )

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "All three filters disabled still produces a coherent graph" do
    scenario "no orphan edges, no spec/review/test nodes; only impl_file remains for components" do
      given_ :context_with_three_children
      given_ :on_configuration_page

      when_ "the engineer disables all three requirement toggles", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: false,
            require_reviews: false,
            require_unit_tests: false
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "the engineer renders the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every edge's source and target are present in the rendered node list",
            context do
        node_keys = MapSet.new(context.graph["nodes"], & &1["key"])

        dangling =
          Enum.filter(context.graph["edges"], fn e ->
            not MapSet.member?(node_keys, e["source"]) or
              not MapSet.member?(node_keys, e["target"])
          end)

        assert dangling == [],
               "expected every edge to point at real nodes with all filters off, found dangling: #{inspect(Enum.map(dangling, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end

      and_ "no node or edge references any spec/review/test artifact name",
           context do
        bad_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "component" and
              n["attributes"]["name"] in @filtered_component_names
          end)

        assert bad_nodes == [],
               "expected no spec/review/test component node, found: #{inspect(Enum.map(bad_nodes, & &1["attributes"]["name"]))}"

        bad_endpoints =
          context.graph["edges"]
          |> Enum.flat_map(fn e -> [e["source"], e["target"]] end)
          |> Enum.filter(fn k ->
            Enum.any?(@filtered_component_names, fn name ->
              String.ends_with?(k, "_" <> name)
            end)
          end)

        assert bad_endpoints == [],
               "expected no edge to reference a filtered artifact node, found: #{inspect(bad_endpoints)}"

        {:ok, context}
      end

      and_ "the only remaining component-typed nodes are implementation_file",
           context do
        remaining_component_names =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_type"] == "component" end)
          |> Enum.map(fn n -> n["attributes"]["name"] end)
          |> Enum.uniq()
          |> Enum.sort()

        assert remaining_component_names == ["implementation_file"],
               "expected only implementation_file among component nodes with all filters off, got: #{inspect(remaining_component_names)}"

        {:ok, context}
      end
    end
  end
end
