defmodule CodeMySpecWeb.WorkingCopyLive.StoryGraphLayout do
  @moduledoc "Dependency columns for components, surrounded by the story's milestones."

  def arrange(flow) do
    component_ids =
      for {id, node} <- flow.nodes,
          node.type == :context or match?(%{requirement: %{entity_type: "component"}}, node.data),
          into: MapSet.new(),
          do: id

    edges = for {_, edge} <- flow.edges, do: {edge.source, edge.target}
    after_components = downstream(MapSet.to_list(component_ids), edges, MapSet.new())
    other_ids = MapSet.difference(MapSet.new(Map.keys(flow.nodes)), component_ids)
    post = MapSet.intersection(other_ids, after_components)
    pre = MapSet.difference(other_ids, post)

    pre_depths = depths(pre, edges)
    component_depths = depths(component_ids, edges)
    post_depths = depths(post, edges)
    component_offset = column_count(pre_depths)
    post_offset = component_offset + column_count(component_depths)

    columns =
      pre_depths
      |> Map.merge(
        Map.new(component_depths, fn {id, depth} -> {id, depth + component_offset} end)
      )
      |> Map.merge(Map.new(post_depths, fn {id, depth} -> {id, depth + post_offset} end))

    column_width =
      Enum.reduce(flow.nodes, 260, fn {_, node}, width -> max(width, node.width || 260) end) + 100

    nodes =
      columns
      |> Enum.group_by(fn {_, column} -> column end, fn {id, _} -> flow.nodes[id] end)
      |> Enum.flat_map(fn {column, nodes} ->
        {placed, _height} =
          nodes
          |> Enum.sort_by(&{&1.data.label, &1.id})
          |> Enum.map_reduce(0, fn node, y ->
            placed = %{node | position: %{x: column * column_width, y: y}}
            {{node.id, placed}, y + (node.height || 112) + 40}
          end)

        placed
      end)
      |> Map.new()

    %{flow | nodes: nodes}
  end

  # Condense cycles before assigning longest-path depth. Every member of a
  # cycle shares one column; an independent leaf always starts at depth zero.
  defp depths(ids, edges) do
    graph = :digraph.new()

    try do
      Enum.each(ids, &:digraph.add_vertex(graph, &1))

      for {from, to} <- edges,
          MapSet.member?(ids, from),
          MapSet.member?(ids, to),
          do: :digraph.add_edge(graph, from, to)

      condensed = :digraph_utils.condensation(graph)

      try do
        condensed
        |> :digraph_utils.topsort()
        |> Enum.reduce(%{}, fn members, depths ->
          depth =
            condensed
            |> :digraph.in_neighbours(members)
            |> Enum.map(&(Map.fetch!(depths, hd(&1)) + 1))
            |> Enum.max(fn -> 0 end)

          Enum.reduce(members, depths, &Map.put(&2, &1, depth))
        end)
      after
        :digraph.delete(condensed)
      end
    after
      :digraph.delete(graph)
    end
  end

  defp column_count(depths), do: Enum.max(Map.values(depths), fn -> -1 end) + 1

  defp downstream([], _edges, seen), do: seen

  defp downstream([id | rest], edges, seen) do
    if MapSet.member?(seen, id) do
      downstream(rest, edges, seen)
    else
      next = for {^id, target} <- edges, do: target
      downstream(rest ++ next, edges, MapSet.put(seen, id))
    end
  end
end
