defmodule CodeMySpecSpex.Story671.Criterion5765Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5765 — Child component nodes still appear in the graph
  when all three require_* filters are disabled.

  Reproduces the bug observed against MarketMySpec, whose
  configuration has `require_specs`, `require_reviews`, and
  `require_unit_tests` all set to false. Under those toggles the
  context_graph's parent fan-out points (`spec_valid` and
  `review_valid`) are stripped. The projector's
  `partition_children_reqs/4` then sees zero fan-outs and returns
  empty `:spec_reqs` / `:impl_reqs` for every child, so
  `build_phase_child_sigma` emits no nodes and every child
  component disappears from the rendered graph.

  This criterion pins the invariant: regardless of which
  artifact-type toggles are off, every child of a context that has
  at least one surviving requirement must still produce at least
  one node in the rendered graph. If the projector strips children
  because the layout assumes a fan-out exists, that's a bug in the
  layout, not in the graph contract.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Children survive in the graph with all three filters disabled" do
    scenario "every child component still has at least one rendered node" do
      given_ :context_with_module_typed_children
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
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "each child component has at least one requirement node",
            context do
        children = [context.child_strategy, context.child_overview]

        Enum.each(children, fn child ->
          child_nodes =
            Enum.filter(context.graph["nodes"], fn n ->
              n["attributes"]["entity_id"] == child.id
            end)

          assert child_nodes != [],
                 "expected at least one node for #{child.module_name} with all filters off, found none"
        end)

        {:ok, context}
      end
    end
  end
end
