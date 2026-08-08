defmodule CodeMySpec.Requirements.Topology do
  @moduledoc """
  Pure graph-shape facts derived from `{nodes, edges}`.

  Every function here answers a structural question — partition,
  reachability, degree, depth — without reading any domain
  metadata. The only fields it consults on requirement nodes are
  the foreign-key fields the graph already carries:

  - `entity_type` (`"project"` / `"story"` / `"component"`)
  - `entity_id`
  - `parent_entity_id`

  …plus `name` solely as part of the node key.

  Names of specific requirements (e.g. `"qa_journey_plan"`,
  `"spec_valid"`) and component-type strings (e.g. `"context"`,
  `"schema"`) never appear here. Layout rules that used to depend
  on those names should ask Topology for the underlying graph fact
  instead — fan-in, fan-out, cross-entity seams, depth — and pixel
  decisions stay in the projector.

  Edge endpoints are tuples `{entity_type, entity_id, name}` (the
  same shape `RequirementGraph` produces). Node-level lookups use
  the same tuple as the canonical key.
  """

  import Bitwise

  alias CodeMySpec.Requirements.Requirement

  @type node_key :: {String.t(), any(), String.t()}
  @type edge :: %{from: node_key(), to: node_key()}
  @type partition :: %{any() => {[Requirement.t()], [edge()]}}

  @doc """
  Canonical lookup key for a requirement node:
  `{entity_type, entity_id, name}`. The shape callers need to
  index nodes, build MapSets, and identify edge endpoints.
  """
  @spec node_key(Requirement.t()) :: node_key()
  def node_key(%Requirement{entity_type: t, entity_id: id, name: n}), do: {t, id, n}

  @doc """
  Group nodes by `entity_type`. Returns a map from type string to
  `{nodes, edges}` where `edges` are exactly those edges with both
  endpoints in the partition's nodes (i.e., intra-type edges).

  Cross-type edges are not included in any partition's edges — get
  them from `cross_entity_edges/1`.
  """
  @spec partition_by_entity_type([Requirement.t()], [edge()]) :: partition()
  def partition_by_entity_type(nodes, edges) do
    partition(nodes, edges, & &1.entity_type)
  end

  @doc """
  Group nodes by `{entity_type, entity_id}` — one bucket per
  individual entity (one story, one component, one project).

  Useful for laying out per-entity subgraphs (e.g., a story's
  vertical chain, a component's column).
  """
  @spec partition_by_entity([Requirement.t()], [edge()]) :: partition()
  def partition_by_entity(nodes, edges) do
    partition(nodes, edges, fn n -> {n.entity_type, n.entity_id} end)
  end

  @doc """
  Group nodes by `parent_entity_id` (the orchestration parent FK
  carried on the requirement). Nodes with `parent_entity_id == nil`
  fall in the `nil` bucket.

  Within an orchestrated tree (e.g., a context with children), the
  parent's parent-scope nodes and each child's child-scope nodes
  share the same `parent_entity_id`, so they all land in the same
  bucket. Use this when laying out a parent + its children as a
  unit.
  """
  @spec partition_by_parent_entity([Requirement.t()], [edge()]) :: partition()
  def partition_by_parent_entity(nodes, edges) do
    partition(nodes, edges, & &1.parent_entity_id)
  end

  @doc """
  Edges whose source and target have different `entity_type`. The
  seams between entity-type subgraphs.
  """
  @spec cross_entity_edges([edge()]) :: [edge()]
  def cross_entity_edges(edges) do
    Enum.filter(edges, &cross_entity?/1)
  end

  @doc """
  Nodes that have at least one outgoing cross-entity edge. The
  upstream side of each seam.
  """
  @spec cross_entity_sources([Requirement.t()], [edge()]) :: [Requirement.t()]
  def cross_entity_sources(nodes, edges) do
    source_keys =
      edges
      |> Enum.filter(&cross_entity?/1)
      |> MapSet.new(& &1.from)

    Enum.filter(nodes, &MapSet.member?(source_keys, key(&1)))
  end

  @doc """
  Nodes that have at least one incoming cross-entity edge. The
  downstream side of each seam.
  """
  @spec cross_entity_sinks([Requirement.t()], [edge()]) :: [Requirement.t()]
  def cross_entity_sinks(nodes, edges) do
    target_keys =
      edges
      |> Enum.filter(&cross_entity?/1)
      |> MapSet.new(& &1.to)

    Enum.filter(nodes, &MapSet.member?(target_keys, key(&1)))
  end

  @doc """
  Topological depth of every node. Sources (no incoming edges)
  have depth 0; everything else is `max(depth of incoming sources) + 1`.

  Edges that reference nodes outside `nodes` (dangling endpoints)
  are ignored — they neither contribute to nor block depth
  resolution. Cycles are broken arbitrarily.
  """
  @spec depth_map([Requirement.t()], [edge()]) :: %{node_key() => non_neg_integer()}
  def depth_map(nodes, edges) do
    node_keys = MapSet.new(nodes, &key/1)
    valid = Enum.filter(edges, &both_endpoints_in?(&1, node_keys))
    incoming = group_edges(valid, & &1.to, & &1.from)

    initial =
      Map.new(nodes, fn n ->
        k = key(n)
        if Map.get(incoming, k, []) == [], do: {k, 0}, else: {k, nil}
      end)

    resolve_depths(initial, incoming)
  end

  defp both_endpoints_in?(%{from: f, to: t}, node_keys) do
    MapSet.member?(node_keys, f) and MapSet.member?(node_keys, t)
  end

  @doc """
  Indegree count for each node (number of incoming edges). Useful
  for finding fan-in points without naming them.
  """
  @spec indegree([Requirement.t()], [edge()]) :: %{node_key() => non_neg_integer()}
  def indegree(nodes, edges) do
    counts = Enum.frequencies_by(edges, & &1.to)
    Map.new(nodes, fn n -> {key(n), Map.get(counts, key(n), 0)} end)
  end

  @doc """
  Outdegree count for each node (number of outgoing edges). Useful
  for finding fan-out points without naming them.
  """
  @spec outdegree([Requirement.t()], [edge()]) :: %{node_key() => non_neg_integer()}
  def outdegree(nodes, edges) do
    counts = Enum.frequencies_by(edges, & &1.from)
    Map.new(nodes, fn n -> {key(n), Map.get(counts, key(n), 0)} end)
  end

  @doc """
  Forward BFS from `from_nodes`. Returns the set of every node key
  reachable along outgoing edges, EXCLUDING the starting set
  itself.

  Used to classify "is this node downstream of any of these other
  nodes?" without enumerating intermediate paths.
  """
  @spec descendants_of([Requirement.t()], [edge()]) :: MapSet.t(node_key())
  def descendants_of(from_nodes, edges) do
    from_keys = MapSet.new(from_nodes, &key/1)
    outgoing = group_edges(edges, & &1.from, & &1.to)
    bfs_descendants(MapSet.to_list(from_keys), MapSet.new(), outgoing)
  end

  defp bfs_descendants([], visited, _outgoing), do: visited

  defp bfs_descendants([k | rest], visited, outgoing) do
    successors = Map.get(outgoing, k, [])
    to_add = Enum.reject(successors, &MapSet.member?(visited, &1))
    new_visited = Enum.reduce(to_add, visited, &MapSet.put(&2, &1))
    bfs_descendants(rest ++ to_add, new_visited, outgoing)
  end

  @doc """
  Returns `edges` with transitively-redundant edges removed. An
  edge `A → B` is redundant iff there exists a path
  `A → … → B` of length ≥ 2 — i.e., one of `A`'s other successors
  reaches `B`. The longer path enforces the same gating, so
  reachability is preserved.

  Cycles are handled rather than merely survived: strongly-connected
  components are condensed first, so every member of a cycle reaches
  every other and no edge carrying the cycle is dropped. This used to
  say cycle behaviour was undefined; it is now defined and pinned by
  tests, which matters because `finalize_unresolved/1` exists only
  because cycles occur here in practice.
  """
  @spec transitive_reduction([edge()]) :: [edge()]
  def transitive_reduction(edges) do
    outgoing = group_edges(edges, & &1.from, & &1.to)
    {bit, reach} = reachability(edges, outgoing)

    # Once per source, not once per edge. A source with twenty-four successors
    # otherwise rebuilt the same union twenty-four times.
    via_successors =
      Map.new(outgoing, fn {a, successors} ->
        {a, Enum.reduce(successors, 0, fn s, acc -> acc ||| Map.get(reach, s, 0) end)}
      end)

    Enum.reject(edges, fn %{from: a, to: b} ->
      redundant?(a, b, outgoing, bit, reach, via_successors)
    end)
  end

  # Reachability as one integer per node, each bit a node.
  #
  # The previous implementation ran a fresh DFS per distinct successor, with no
  # sharing between them, so cost scaled with (distinct successors × edges).
  # Measured on a 1045-node graph: 26ms when edges landed on 144 distinct
  # targets, 471ms when they landed on 1035 — the same edge count, eighteen
  # times the work, purely from how spread out the targets were. Real
  # requirement graphs are the spread-out kind.
  #
  # Bignum `bor` on a 1045-bit integer is one BEAM operation, so a node's whole
  # reachable set merges in constant-ish time and each edge is visited once.
  #
  # Cycles are real here — `finalize_unresolved/1` exists precisely because
  # nodes fail to resolve a depth — so this condenses strongly-connected
  # components first. Within an SCC everything reaches everything, and the
  # condensation is a DAG by construction, which is what makes a single
  # reverse-topological pass correct.
  defp reachability(edges, outgoing) do
    nodes = edges |> Enum.flat_map(&[&1.from, &1.to]) |> Enum.uniq()
    bit = nodes |> Enum.with_index() |> Map.new(fn {n, i} -> {n, 1 <<< i} end)

    graph = :digraph.new()

    try do
      Enum.each(nodes, &:digraph.add_vertex(graph, &1))
      Enum.each(edges, fn %{from: f, to: t} -> :digraph.add_edge(graph, f, t) end)

      condensed = :digraph_utils.condensation(graph)

      try do
        {bit, scc_reachability(condensed, outgoing, bit)}
      after
        :digraph.delete(condensed)
      end
    after
      :digraph.delete(graph)
    end
  end

  defp scc_reachability(condensed, outgoing, bit) do
    order = condensed |> :digraph_utils.topsort() |> Enum.reverse()

    masks =
      Map.new(order, fn scc -> {scc, Enum.reduce(scc, 0, &(&2 ||| Map.get(bit, &1, 0)))} end)

    scc_reach =
      Enum.reduce(order, %{}, fn scc, acc ->
        reachable =
          condensed
          |> :digraph.out_neighbours(scc)
          |> Enum.reduce(0, fn nxt, sum ->
            sum ||| Map.get(masks, nxt, 0) ||| Map.get(acc, nxt, 0)
          end)

        Map.put(acc, scc, reachable)
      end)

    # Back to individual nodes. A node in a multi-member SCC reaches every
    # member including itself; a lone node reaches itself only via a self-loop.
    for scc <- order, node <- scc, into: %{} do
      own =
        cond do
          length(scc) > 1 -> Map.fetch!(masks, scc)
          node in Map.get(outgoing, node, []) -> Map.get(bit, node, 0)
          true -> 0
        end

      {node, Map.fetch!(scc_reach, scc) ||| own}
    end
  end

  # `A → B` is redundant when another successor of `A` reaches `B`. "Another"
  # matters only when `B` reaches itself — otherwise `B`'s own reach set cannot
  # contain `B` and the cheap union is already exact.
  defp redundant?(a, b, outgoing, bit, reach, via_successors) do
    b_bit = Map.get(bit, b, 0)

    cond do
      # Nothing A's successors reach is B: the edge is the only way there.
      (Map.get(via_successors, a, 0) &&& b_bit) == 0 ->
        false

      # B cannot reach itself, so the union above cannot be B's own doing.
      (Map.get(reach, b, 0) &&& b_bit) == 0 ->
        true

      # B is on a cycle. Now it matters which successor supplied the bit, so
      # ask each one — the only case that costs more than two bit tests, and
      # it needs a cycle through B to happen at all.
      true ->
        Enum.any?(Map.get(outgoing, a, []), fn s ->
          s != b and (Map.get(reach, s, 0) &&& b_bit) != 0
        end)
    end
  end

  @doc """
  True iff `node` has at least one outgoing edge to one of its
  children — a node that shares `node`'s `entity_type` AND whose
  `parent_entity_id` is `node.entity_id`. The structural signature
  of "parent fans out to children," distinct from sibling/cross-
  context edges (which would have a different `parent_entity_id`).

  For batch detection across a graph, use `fan_out_keys/2` — it
  computes the same predicate for every node in O(N+E) instead of
  the O(N×E) you'd get from filtering with this function.
  """
  @spec fans_out_to_children?(Requirement.t(), [Requirement.t()], [edge()]) :: boolean()
  def fans_out_to_children?(node, nodes, edges) do
    fan_out_keys(nodes, edges)
    |> MapSet.member?(key(node))
  end

  @doc """
  The set of node keys whose nodes fan out to children — see
  `fans_out_to_children?/3` for the predicate. Computes the answer
  for every node in one O(N+E) pass instead of O(N×E).
  """
  @spec fan_out_keys([Requirement.t()], [edge()]) :: MapSet.t(node_key())
  def fan_out_keys(nodes, edges) do
    by_key = Map.new(nodes, &{key(&1), &1})

    edges
    |> Enum.reduce(MapSet.new(), fn %{from: from_key, to: to_key}, acc ->
      with %_{} = source <- Map.get(by_key, from_key),
           %_{} = target <- Map.get(by_key, to_key),
           true <- target.entity_type == source.entity_type,
           true <- target.entity_id != source.entity_id,
           true <- target.parent_entity_id == source.entity_id do
        MapSet.put(acc, from_key)
      else
        _ -> acc
      end
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Generic partitioner. Buckets nodes by `key_fn`, then assigns each
  # edge to the bucket(s) whose nodes contain BOTH endpoints — using
  # the bucket's node-key set as the source of truth. Edges crossing
  # buckets fall out (callers retrieve them from `cross_entity_edges/1`
  # or compute them as `edges -- bucket_edges`).
  defp partition(nodes, edges, key_fn) do
    nodes
    |> Enum.group_by(key_fn)
    |> Map.new(fn {bucket_key, bucket_nodes} ->
      bucket_node_keys = MapSet.new(bucket_nodes, &key/1)

      bucket_edges =
        Enum.filter(edges, fn e ->
          MapSet.member?(bucket_node_keys, e.from) and
            MapSet.member?(bucket_node_keys, e.to)
        end)

      {bucket_key, {bucket_nodes, bucket_edges}}
    end)
  end

  defp cross_entity?(%{from: {ft, _, _}, to: {tt, _, _}}), do: ft != tt

  defp key(n), do: node_key(n)

  defp group_edges(edges, group_fn, value_fn) do
    Enum.reduce(edges, %{}, fn e, acc ->
      Map.update(acc, group_fn.(e), [value_fn.(e)], &[value_fn.(e) | &1])
    end)
  end

  defp resolve_depths(depths, incoming) do
    {updated, changed?} =
      Enum.map_reduce(depths, false, &maybe_assign_depth(&1, &2, depths, incoming))

    updated_map = Map.new(updated)

    cond do
      changed? -> resolve_depths(updated_map, incoming)
      Enum.any?(updated_map, fn {_k, d} -> is_nil(d) end) -> finalize_unresolved(updated_map)
      true -> updated_map
    end
  end

  defp maybe_assign_depth({k, depth}, any_changed, _depths, _incoming) when not is_nil(depth) do
    {{k, depth}, any_changed}
  end

  defp maybe_assign_depth({k, _nil}, any_changed, depths, incoming) do
    sources = Map.get(incoming, k, [])
    source_depths = Enum.map(sources, &Map.get(depths, &1))

    if Enum.all?(source_depths, &(not is_nil(&1))) do
      {{k, Enum.max(source_depths, fn -> -1 end) + 1}, true}
    else
      {{k, nil}, any_changed}
    end
  end

  # Cyclic nodes (those that never resolved) get sequential depths in
  # stable key order, starting at max-known + 1. This stops cycles
  # from collapsing to the same depth band (and the same y in
  # GraphProjector), at the cost of one back-edge per cycle — the
  # unavoidable tradeoff for rendering a cycle in a downward-flowing
  # layout.
  defp finalize_unresolved(depths) do
    max_known =
      depths
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> -1 end)

    unresolved =
      depths
      |> Enum.filter(fn {_k, d} -> is_nil(d) end)
      |> Enum.sort_by(fn {k, _} -> k end)

    unresolved
    |> Enum.with_index()
    |> Enum.reduce(depths, fn {{k, _}, idx}, acc ->
      Map.put(acc, k, max_known + 1 + idx)
    end)
  end
end
