defmodule CodeMySpec.Requirements.NodeRepository do
  @moduledoc """
  Writes computed requirement nodes to rows, and reads what they say.

  One upsert per entity type, because the identity is a partial unique index per
  entity type and Postgres wants a concrete conflict target. Splitting on the
  owner is what lets `insert_all` name one.

  ## Why upsert rather than replace

  A node's row id is what edges point at. Deleting and reinserting would issue
  new ids on every graph computation and orphan every edge — so rows persist and
  only the verdict moves.

  That is also why `on_conflict` names its columns instead of `:replace_all`:
  `inserted_at` must survive, and so must the id.

  ## Reading

  These rows plus `requirement_edges` are a read model, and questions about the
  graph's *current* shape can be answered from them without recomputing
  anything. `actionable_count/1` is the first such reader; the recompute path
  exists to keep the rows true, not to answer every question about them.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Requirement}
  alias CodeMySpec.Users.Scope

  @replace {:replace, [:satisfied, :details, :description, :checked_at, :updated_at]}

  @doc """
  How many requirements are unsatisfied with every prerequisite met.

  A read-model query and nothing else: unsatisfied nodes belonging to the
  project, minus any with an incoming edge from a node that is itself
  unsatisfied. No preload, no fingerprint, no cache, and no filesystem.

  That last part is why this exists. The obvious reader —
  `RequirementGraph.next_actionable/1` — recomputes on a cache miss, the
  recompute runs the checkers, and the checkers glob the working copy. For a
  harness-served project the stop decision runs *inside the channel process*, so
  the process that would serve the glob is the one blocked waiting for it
  (`harness_project_channel_test`, 4949ms, "it accepted the request and did not
  answer"). Reading the cache instead avoided the deadlock and answered almost
  never: `GraphFingerprint.compute/2` hashes the file digest, and the stop hook
  syncs files before it decides, so the entry is always stale by then.

  Both of those were attempts to compute an answer the rows already hold.

  Scoped three ways because the rows are, deliberately: `project_id` is set only
  on project-level nodes, while component and story requirements carry
  `component_id` or `story_id` and leave it null. A filter on `project_id` alone
  selects the project-level handful and silently misses the rest — measured at 5
  of 57 on a real working copy.

  Not identical to `next_actionable/1`, which also drops component requirements
  with no inherited story priority. Measured 57 here against that path's 58, and
  the difference is that filter rather than a disagreement about the graph.
  """
  @spec actionable_count(Scope.t()) :: non_neg_integer()
  def actionable_count(%Scope{active_project_id: nil}), do: 0

  def actionable_count(%Scope{active_project_id: project_id}) do
    blocked =
      from(e in Edge,
        join: prereq in Node,
        on: prereq.id == e.from_requirement_id,
        where: prereq.satisfied == false,
        select: e.to_requirement_id
      )

    # `type/2` on both, because these are schemaless queries: naming a table
    # rather than a schema leaves Ecto with no field definition to cast against,
    # so a UUID string reaches Postgrex uncast and it refuses — "expected a
    # binary of 16 bytes". The outer `project_id` needs none, since `Node` is a
    # schema and knows its own field is a binary id.
    from(n in Node,
      where: n.satisfied == false,
      where: n.id not in subquery(blocked),
      where:
        n.project_id == ^project_id or
          n.component_id in subquery(
            from(c in "components",
              where: c.project_id == type(^project_id, :binary_id),
              select: c.id
            )
          ) or
          n.story_id in subquery(
            from(s in "stories",
              where: s.project_id == type(^project_id, :binary_id),
              select: s.id
            )
          )
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Persist computed nodes, returning them keyed by `Topology.node_key/1`.

  The map is the point: it is how an edge turns a `{entity_type, entity_id, name}`
  pair into the two row ids it needs.
  """
  @spec upsert_all(Scope.t(), [Requirement.t()]) :: %{tuple() => integer()}
  def upsert_all(%Scope{active_project_id: project_id} = scope, nodes) when is_list(nodes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    nodes
    |> Enum.group_by(& &1.entity_type)
    |> Enum.each(fn {entity_type, group} ->
      upsert_group(entity_type, group, now)
    end)

    keys = ids_by_key(project_id, nodes)
    delete_departed(scope, nodes, keys)
    keys
  end

  # Nodes that were in the graph and are not any more.
  #
  # `upsert_all/2` inserted and updated and never removed, so every node ever
  # computed stayed a row. That is not a leak, it is wrong answers: a project
  # whose configuration stops requiring specs drops `spec_file` from its graph,
  # and without this those 798 rows kept being served as unsatisfied work. The
  # graph read 2,783 nodes where the computation produced 1,357 — 1,426
  # requirements an agent was told to do that its project does not have.
  #
  # `replace_edges/3` already did the equivalent for edges. Nodes had no such
  # pass, and the asymmetry was invisible because both halves round-tripped
  # consistently: the projection agreed with itself, just not with the graph.
  #
  # Scoped to the entities this computation covered, not to the project. A
  # component the graph did not visit — filtered out, or belonging to work not
  # loaded — must keep its rows rather than be treated as departed.
  defp delete_departed(%Scope{active_project_id: project_id}, nodes, keys) do
    keep = keys |> Map.values() |> MapSet.new()

    component_ids = entity_ids(nodes, "component")
    story_ids = entity_ids(nodes, "story")

    Node
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    |> select([n], n.id)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> case do
      [] -> :ok
      ids -> Repo.delete_all(from(n in Node, where: n.id in ^ids))
    end
  end

  @doc """
  Persist the graph's edges against the node ids `upsert_all/2` returned.

  Takes the key map rather than looking nodes up again: the caller has just paid
  for it, and an edge whose endpoints are not in it names a node this graph does
  not contain. Those are dropped rather than inserted — `compute_edges/3` already
  filters to known nodes, so one here means the two passes disagree, and a
  foreign key error at 3am is a worse way to find that out than an edge count
  that does not match.

  Stale edges go: a dependency removed from a definition must stop being a row,
  and the project's edges are the unit that recomputation replaces.
  """
  @spec replace_edges(Scope.t(), [%{from: tuple(), to: tuple()}], %{tuple() => integer()}) ::
          {:ok, non_neg_integer()}
  def replace_edges(%Scope{}, edges, ids_by_key) do
    rows =
      edges
      |> Enum.flat_map(fn %{from: from, to: to} ->
        case {Map.get(ids_by_key, from), Map.get(ids_by_key, to)} do
          {nil, _} -> []
          {_, nil} -> []
          {from_id, to_id} when from_id == to_id -> []
          {from_id, to_id} -> [%{from_requirement_id: from_id, to_requirement_id: to_id}]
        end
      end)
      |> Enum.uniq()

    node_ids = Map.values(ids_by_key)

    Repo.transaction(fn ->
      delete_edges_outside(node_ids, rows)

      {count, _} =
        Repo.insert_all(Edge, stamp(rows),
          on_conflict: :nothing,
          conflict_target: [:from_requirement_id, :to_requirement_id]
        )

      count
    end)
  end

  defp stamp(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    Enum.map(rows, &Map.put(&1, :inserted_at, now))
  end

  # Only edges among *this* graph's nodes are ours to remove. Deleting by
  # project would take edges belonging to nodes this computation did not
  # produce, and there is no project column here to do it with anyway.
  defp delete_edges_outside(node_ids, keep) do
    keep_pairs = MapSet.new(keep, &{&1.from_requirement_id, &1.to_requirement_id})

    Edge
    |> where([e], e.from_requirement_id in ^node_ids)
    |> select([e], {e.id, e.from_requirement_id, e.to_requirement_id})
    |> Repo.all()
    |> Enum.reject(fn {_id, from, to} -> MapSet.member?(keep_pairs, {from, to}) end)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> :ok
      ids -> Repo.delete_all(from(e in Edge, where: e.id in ^ids))
    end
  end

  defp upsert_group(entity_type, nodes, now) do
    {owner_field, conflict_target} = owner(entity_type)

    entries =
      Enum.map(nodes, fn node ->
        %{
          name: node.name,
          description: node.description || node.name,
          satisfied: node.satisfied,
          details: node.details || %{},
          checked_at: now,
          inserted_at: now,
          updated_at: now
        }
        |> Map.put(owner_field, node.entity_id)
      end)

    Repo.insert_all(Node, entries, on_conflict: @replace, conflict_target: conflict_target)
  end

  # Only the owner column is set: `Map.put(owner_field, entity_id)` puts a
  # project node's id in `project_id` and a component node's in `component_id`,
  # leaving the others null. That is what keeps the three partial indexes
  # disjoint — a component node carrying `project_id` would land in two of them.

  defp owner("component"),
    do: {:component_id, {:unsafe_fragment, "(component_id, name) WHERE component_id IS NOT NULL"}}

  defp owner("story"),
    do: {:story_id, {:unsafe_fragment, "(story_id, name) WHERE story_id IS NOT NULL"}}

  defp owner("project"),
    do: {:project_id, {:unsafe_fragment, "(project_id, name) WHERE project_id IS NOT NULL"}}

  # Read back rather than trusting `insert_all`'s returning: an upsert that
  # conflicted returns the existing row, and the ids have to be the same ones
  # edges will reference either way.
  defp ids_by_key(project_id, nodes) do
    names = nodes |> Enum.map(& &1.name) |> Enum.uniq()

    component_ids = entity_ids(nodes, "component")
    story_ids = entity_ids(nodes, "story")

    Node
    |> where([n], n.name in ^names)
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    |> select([n], {n.component_id, n.story_id, n.project_id, n.name, n.id})
    |> Repo.all()
    |> Map.new(fn {component_id, story_id, proj_id, name, id} ->
      {key_for(component_id, story_id, proj_id, name), id}
    end)
  end

  defp entity_ids(nodes, entity_type) do
    nodes |> Enum.filter(&(&1.entity_type == entity_type)) |> Enum.map(& &1.entity_id)
  end

  defp key_for(component_id, _story, _project, name) when not is_nil(component_id),
    do: {"component", component_id, name}

  defp key_for(_component, story_id, _project, name) when not is_nil(story_id),
    do: {"story", story_id, name}

  defp key_for(_component, _story, project_id, name), do: {"project", project_id, name}
end
