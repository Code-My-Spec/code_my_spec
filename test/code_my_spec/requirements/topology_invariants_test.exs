defmodule CodeMySpec.Requirements.TopologyInvariantsTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias CodeMySpec.Requirements.Topology

  test "reduction preserves reachability for every four-node directed graph" do
    for edges <- graphs([:a, :b, :c, :d], false) do
      reduced = Topology.transitive_reduction(edges)
      assert MapSet.subset?(MapSet.new(reduced), MapSet.new(edges))
      assert closure(reduced) == closure(edges), "Lost paths reducing #{inspect(edges)}"
    end
  end

  test "reduction preserves cycles and self-reachability with self-loops" do
    for edges <- graphs([:a, :b, :c], true) do
      assert closure(Topology.transitive_reduction(edges)) == closure(edges),
             "Lost paths reducing #{inspect(edges)}"
    end
  end

  # An independent queue traversal: do not use the production reachability
  # implementation as the oracle for the code that depends on it.
  defp closure(edges) do
    outgoing = Enum.group_by(edges, & &1.from, & &1.to)

    for source <- Map.keys(outgoing),
        target <- walk(Map.get(outgoing, source, []), outgoing, MapSet.new()),
        into: MapSet.new(),
        do: {source, target}
  end

  defp walk([], _outgoing, seen), do: seen

  defp walk([node | rest], outgoing, seen) do
    walk_next(MapSet.member?(seen, node), node, rest, outgoing, seen)
  end

  defp walk_next(true, _node, rest, outgoing, seen), do: walk(rest, outgoing, seen)

  defp walk_next(false, node, rest, outgoing, seen),
    do: walk(rest ++ Map.get(outgoing, node, []), outgoing, MapSet.put(seen, node))

  defp graphs(nodes, loops?) do
    for(from <- nodes, to <- nodes, loops? or from != to, do: edge(from, to))
    |> subsets()
  end

  defp subsets(items) do
    indexed = Enum.with_index(items)

    for mask <- 0..((1 <<< length(items)) - 1) do
      for {item, index} <- indexed, (mask &&& 1 <<< index) != 0, do: item
    end
  end

  defp edge(from, to), do: %{from: from, to: to}
end
