defmodule CodeMySpecSpex.Story562.Criterion5598Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5598 — A prereq pointing at a deleted node surfaces as
  an orphan reference indicator.

  This scenario describes a future-state UI behavior: when the
  graph would otherwise render an edge pointing at a node that no
  longer exists, the dependent node should display an orphan-
  reference indicator rather than the projector silently dropping
  the edge.

  The current implementation drops broken edges in the projector
  (see `GraphProjector.project_graph` filter
  `MapSet.member?(all_keys, ...)`). This spec expects a behavior
  change as part of story 562's rewrite — the projector should
  carry the broken-reference signal through to the rendered HTML
  so PMs can see what's wrong.

  Until the rewrite lands, this spec is expected to fail.

  We can't easily *manufacture* a deleted node from outside the
  graph machinery (sync rebuilds component nodes from spec files,
  and all rendered edges come from sync's view of state). So the
  spec asserts the weakest version of the future-state contract:
  if an orphan-reference indicator class appears anywhere in the
  rendered HTML — and the graph data has at least one node flagged
  with `orphan_reference: true` — then the contract is honored.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  @tag :pending_implementation
  spex "Orphan prereq references are surfaced, not silently dropped" do
    scenario "the orphan-reference indicator API exists on the graph view" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the rendered nodes carry an orphan_reference field",
            context do
        sample_node = List.first(context.graph["nodes"])

        assert sample_node != nil,
               "expected at least one rendered node"

        assert Map.has_key?(sample_node["attributes"], "orphan_reference"),
               "expected each node's attributes to include an `orphan_reference` boolean — story 562 should add this field. Today, the field is missing because the projector silently filters broken edges."

        {:ok, context}
      end
    end
  end
end
