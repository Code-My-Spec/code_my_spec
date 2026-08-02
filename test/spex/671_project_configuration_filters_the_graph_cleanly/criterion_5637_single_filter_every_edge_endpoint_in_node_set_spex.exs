defmodule CodeMySpecSpex.Story671.Criterion5637Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5637 — With a single filter active (require_reviews
  false), every edge endpoint in the rendered graph is present in
  the rendered node set, and no edge references a node with name
  "review_file" or "review_valid".
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Single filter active produces a coherent graph" do
    scenario "every edge has both endpoints in nodes; no edge references a review node" do
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
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

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
               "expected every edge to point at real nodes, found dangling: #{inspect(Enum.map(dangling, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end

      and_ "no edge references a review_file or review_valid node",
           context do
        offenders =
          context.graph["edges"]
          |> Enum.flat_map(fn e -> [e["source"], e["target"]] end)
          |> Enum.filter(fn k ->
            String.ends_with?(k, "_review_file") or String.ends_with?(k, "_review_valid")
          end)

        assert offenders == [],
               "expected no edge to reference a review node, found endpoints: #{inspect(offenders)}"

        {:ok, context}
      end
    end
  end
end
