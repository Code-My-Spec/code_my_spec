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

  Names of specific requirements (e.g. `"qa_preflight"`,
  `"spec_valid"`) and component-type strings (e.g. `"context"`,
  `"schema"`) never appear here. Layout rules that used to depend
  on those names should ask Topology for the underlying graph fact
  instead — fan-in, fan-out, cross-entity seams, depth — and pixel
  decisions stay in the projector.

  Edge endpoints are tuples `{entity_type, entity_id, name}` (the
  same shape `RequirementGraph` produces). Node-level lookups use
  the same tuple as the canonical key.
  """

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
    partition(nodes, edges, &(&1.entity_type))
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
    {updated, changed?} = Enum.map_reduce(depths, false, &maybe_assign_depth(&1, &2, depths, incoming))
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

  defp finalize_unresolved(depths) do
    Map.new(depths, fn
      {k, nil} -> {k, 0}
      {k, d} -> {k, d}
    end)
  end
end
