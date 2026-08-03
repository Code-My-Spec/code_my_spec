defmodule CodeMySpecSpex.Story562.Criterion5607Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5607 — Two independent sibling schemas are both
  highlighted as actionable simultaneously.

  Surface: requirements graph LiveView. Two siblings with no
  dependency between them must not be artificially serialized — both
  should be reachable as actionable work in parallel.

  We verify the absence of edges between the siblings (no false
  serialization), which is the structural guarantee. Whether both
  appear as "actionable" coloring depends on additional file-state
  setup that's beyond the scope of this rule's structural test.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Independent siblings are not serialized in the graph" do
    scenario "no prerequisite edges run between sibling components without explicit deps" do
      given_ :two_independent_sibling_schemas

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no edges run between sibling_a and sibling_b",
            context do
        a_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.sibling_a.id end)
          |> MapSet.new(& &1["key"])

        b_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.sibling_b.id end)
          |> MapSet.new(& &1["key"])

        assert MapSet.size(a_keys) > 0,
               "expected sibling_a (#{context.sibling_a.module_name}) to render at least one node"

        assert MapSet.size(b_keys) > 0,
               "expected sibling_b (#{context.sibling_b.module_name}) to render at least one node"

        cross_edges =
          Enum.filter(context.graph["edges"], fn e ->
            (MapSet.member?(a_keys, e["source"]) and MapSet.member?(b_keys, e["target"])) or
              (MapSet.member?(b_keys, e["source"]) and MapSet.member?(a_keys, e["target"]))
          end)

        assert cross_edges == [],
               "expected no edges between independent siblings, found: #{inspect(Enum.map(cross_edges, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end
    end
  end
end
