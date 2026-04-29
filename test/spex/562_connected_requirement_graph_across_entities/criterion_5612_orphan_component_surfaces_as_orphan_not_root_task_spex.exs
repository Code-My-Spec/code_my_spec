defmodule CodeMySpecSpex.Story562.Criterion5612Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5612 — A component with no parent context and no story
  linkage surfaces as an orphan, not as a root task.

  Surface: requirements graph LiveView. An orphan component (no
  parent, no story) should appear in the graph in a way that
  signals its disconnected status — typically by having no path to
  the project root, or by being flagged with an orphan indicator.

  This spec is expected to fail until story 562's rewrite lands
  (orphan-indicator UI does not yet exist). The current code
  silently includes orphan components as if they were normal nodes,
  which is exactly what 562 fixes.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Orphan components are visibly orphaned, not silent root tasks" do
    scenario "the orphan component is not reachable from the project root" do
      given_ :context_with_three_children
      given_ :orphan_component

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the orphan component's nodes are disconnected from the project root",
            context do
        nodes = context.graph["nodes"]
        edges = context.graph["edges"]

        orphan_keys =
          nodes
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.orphan.id end)
          |> MapSet.new(& &1["key"])

        assert MapSet.size(orphan_keys) > 0,
               "expected the orphan component to render at least one node — if it doesn't appear at all, that also satisfies the rule but the spec needs adjustment"

        adjacency = build_undirected_adjacency(nodes, edges)

        project_keys =
          nodes
          |> Enum.filter(fn n -> n["attributes"]["entity_type"] == "project" end)
          |> MapSet.new(& &1["key"])

        # Each orphan node's connected component should NOT include any project node
        Enum.each(orphan_keys, fn key ->
          reachable = bfs(key, adjacency)
          intersection = MapSet.intersection(reachable, project_keys)

          assert MapSet.size(intersection) == 0,
                 "expected orphan node #{key} to be disconnected from any project node, but it reaches: #{inspect(MapSet.to_list(intersection))}"
        end)

        {:ok, context}
      end
    end
  end

  defp build_undirected_adjacency(nodes, edges) do
    base = Map.new(nodes, fn n -> {n["key"], MapSet.new()} end)

    Enum.reduce(edges, base, fn e, acc ->
      acc
      |> Map.update(e["source"], MapSet.new([e["target"]]), &MapSet.put(&1, e["target"]))
      |> Map.update(e["target"], MapSet.new([e["source"]]), &MapSet.put(&1, e["source"]))
    end)
  end

  defp bfs(start_key, adjacency) do
    bfs_loop([start_key], MapSet.new([start_key]), adjacency)
  end

  defp bfs_loop([], visited, _adjacency), do: visited

  defp bfs_loop([key | rest], visited, adjacency) do
    neighbors = Map.get(adjacency, key, MapSet.new())
    new_neighbors = MapSet.difference(neighbors, visited)

    bfs_loop(
      rest ++ MapSet.to_list(new_neighbors),
      MapSet.union(visited, new_neighbors),
      adjacency
    )
  end
end
