defmodule CodeMySpecSpex.Story562.Criterion5603Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5603 — Context tests_passing depends on every child's
  terminal requirement.

  Surface: requirements graph LiveView at
  `/projects/:project/requirements/graph`. The page embeds the
  projected graph as JSON in `data-graph` on `#sigma-graph`; this
  spec extracts that JSON and asserts on its node + edge structure.

  This is a fan-in invariant: a bounded context's terminal
  requirement (`tests_passing` on the parent) must depend on every
  child component's terminal requirement, transitively. We verify
  that for each child synced into the topology there is at least one
  edge from a node owned by that child to a node owned by the parent
  context — the structural shape of "fans in."
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context terminal requirement fans in from every child" do
    scenario "every child has at least one edge into the parent context" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every child has at least one edge into a parent-owned node",
            context do
        parent_id = context.parent_context.id
        children = [context.child_schema, context.child_repository, context.child_service]

        parent_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == parent_id end)
          |> MapSet.new(& &1["key"])

        Enum.each(children, fn child ->
          child_keys =
            context.graph["nodes"]
            |> Enum.filter(fn n -> n["attributes"]["entity_id"] == child.id end)
            |> MapSet.new(& &1["key"])

          fan_in_edges =
            Enum.filter(context.graph["edges"], fn e ->
              MapSet.member?(child_keys, e["source"]) and
                MapSet.member?(parent_keys, e["target"])
            end)

          assert fan_in_edges != [],
                 "expected at least one edge from #{child.module_name} into a #{context.parent_context.module_name} node, found none"
        end)

        {:ok, context}
      end
    end
  end
end
