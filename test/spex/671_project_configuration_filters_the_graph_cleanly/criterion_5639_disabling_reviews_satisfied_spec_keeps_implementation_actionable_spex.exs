defmodule CodeMySpecSpex.Story671.Criterion5639Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5639 — Disabling reviews on an in-progress project keeps
  implementation_file actionability tied to spec_valid: when spec_valid
  is satisfied and reviews are off, implementation_file appears as
  actionable, and it is not gated on a removed review node.

  The rendered graph encodes actionability via node color
  (#4ade80 = actionable, #fbbf24 = blocked, #60a5fa = satisfied).
  Asserting on the graph color faithfully reproduces what
  `Requirements.next_actionable_project/1` (the function MCP
  get_next_requirement wraps) returns.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions

  @actionable "#4ade80"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reviews disabled + spec_valid satisfied → impl_file actionable" do
    scenario "impl_file is rendered actionable; no review blocker remains" do
      given_ :synced_context_component

      and_ "the implementation file is removed (in-progress state)",
           context do
        :ok = Environments.delete_file(context.environment, "lib/example_context.ex")

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

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

      then_ "implementation_file renders as actionable", context do
        impl_node =
          GraphAssertions.find_node(
            context.graph,
            "component",
            context.component.id,
            "implementation_file"
          )

        assert impl_node,
               "expected implementation_file node to exist for the synced context component"

        assert impl_node["attributes"]["color"] == @actionable,
               "expected impl_file to render as actionable (color #{@actionable}) when spec_valid is satisfied and reviews are disabled, got: #{impl_node["attributes"]["color"]}"

        {:ok, context}
      end

      and_ "implementation_file is not gated on any review node",
           context do
        impl_key =
          GraphAssertions.node_key("component", context.component.id, "implementation_file")

        review_incoming =
          context.graph
          |> GraphAssertions.edges_to(impl_key)
          |> Enum.filter(fn e ->
            String.ends_with?(e["source"], "_review_file") or
              String.ends_with?(e["source"], "_review_valid")
          end)

        assert review_incoming == [],
               "expected impl_file to have no incoming edge from a review node, found: #{inspect(Enum.map(review_incoming, & &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
