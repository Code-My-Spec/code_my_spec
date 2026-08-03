defmodule CodeMySpecSpex.Story562.Criterion5611Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5611 — Every node in a healthy graph traces back to the
  project root via prerequisite traversal.

  Surface: requirements graph LiveView. With a normal project
  topology (stories + components + deps), every rendered node must
  be reachable from at least one project-rooted node by walking
  edges in the source→target direction (or in reverse, depending on
  edge orientation in the projector). We verify the connected
  component containing each node also contains a project node.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Healthy graph is fully connected to the project root" do
    scenario "every node shares a connected component with at least one project node" do
      given_ :story_with_liveview_surface

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every node shares a connected component with a project node",
            context do
        nodes = context.graph["nodes"]
        edges = context.graph["edges"]

        assert nodes != [], "expected the graph to have nodes"

        adjacency = build_undirected_adjacency(nodes, edges)
        project_keys = MapSet.new(project_node_keys(nodes))

        assert MapSet.size(project_keys) > 0,
               "expected at least one project node in the rendered graph"

        unreachable =
          nodes
          |> Enum.reject(fn n ->
            reachable_from = bfs(n["key"], adjacency)
            Enum.any?(project_keys, &MapSet.member?(reachable_from, &1))
          end)
          |> Enum.map(& &1["key"])

        assert unreachable == [],
               "expected every node to share a connected component with a project node, found unreachable: #{inspect(unreachable)}"

        {:ok, context}
      end
    end
  end

  defp project_node_keys(nodes) do
    nodes
    |> Enum.filter(fn n -> n["attributes"]["entity_type"] == "project" end)
    |> Enum.map(& &1["key"])
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
