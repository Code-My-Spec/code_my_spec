defmodule CodeMySpec.Requirements.NodeRepository do
  @moduledoc """
  Writes computed requirement nodes to rows.

  One upsert per entity type, because the identity is a partial unique index per
  entity type and Postgres wants a concrete conflict target. Splitting on the
  owner is what lets `insert_all` name one.

  ## Why upsert rather than replace

  A node's row id is what edges point at. Deleting and reinserting would issue
  new ids on every graph computation and orphan every edge — so rows persist and
  only the verdict moves.

  That is also why `on_conflict` names its columns instead of `:replace_all`:
  `inserted_at` must survive, and so must the id.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Edge, Node, Requirement}
  alias CodeMySpec.Users.Scope

  @replace {:replace, [:satisfied, :details, :description, :checked_at, :updated_at]}

  @doc """
  Persist computed nodes, returning them keyed by `Topology.node_key/1`.

  The map is the point: it is how an edge turns a `{entity_type, entity_id, name}`
  pair into the two row ids it needs.
  """
  @spec upsert_all(Scope.t(), [Requirement.t()]) :: %{tuple() => integer()}
  def upsert_all(%Scope{active_project_id: project_id}, nodes) when is_list(nodes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    nodes
    |> Enum.group_by(& &1.entity_type)
    |> Enum.each(fn {entity_type, group} ->
      upsert_group(entity_type, group, now)
    end)

    ids_by_key(project_id, nodes)
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
