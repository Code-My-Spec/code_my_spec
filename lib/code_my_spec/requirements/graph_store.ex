defmodule CodeMySpec.Requirements.GraphStore do
  @moduledoc """
  Reads and writes the requirement graph's rows, for the event projection.

  `IncrementalGraph` decides what each entity's requirements are; this is where
  those answers land in `requirements` and `requirement_edges`. Writes are per
  entity and per event: `write/3` replaces what one computation covered,
  `put_verdict/2` and `put_verdicts/5` move a verdict a handler already knew,
  `sweep/2` settles one requirement across every owner of a type, and
  `write_edges/3` writes an edge set as a difference. The projection checks —
  `projected?/1`, `definitions_covered?/2`, `incomplete_entities/2` — tell the
  projector when a vantage's rows cannot be trusted and must be seeded.
  """

  import Ecto.Query, only: [from: 2, where: 2, where: 3, dynamic: 2, select: 3]

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  # Postgres caps a statement at 65,535 bind parameters (one per column per row).
  # Declared before any user: a module attribute read above its definition is `nil`.
  @bind_budget 60_000

  @table {"requirements", Node}
  @edges "requirement_edges"

  @doc "The table the graph's nodes are written to and read from."
  @spec event_target() :: {String.t(), module()}
  def event_target, do: @table

  @doc "The table the graph's edges are written to and read from."
  @spec event_edges() :: String.t()
  def event_edges, do: @edges

  @type entity :: {String.t(), term()}

  @doc """
  Replace the graph rows for everything this computation covered.

  Rows are written by each node's own owner and reaped by `covered`, which are
  separate inputs: a component family is computed together and a member can
  legitimately produce nothing, so "this component now has no requirements" has
  to reap its old rows.

  Upsert then reap, never delete-then-insert: edges reference row ids, so a
  reinserted row orphans every edge touching it. See knowledge/requirements_graph,
  "Edges".

  Answers how many rows arrived and how many departed, so the caller knows
  whether the node set moved and edges must be redrawn.
  """
  @spec write(Scope.t(), Enumerable.t(), [map()]) ::
          {:ok, %{inserted: non_neg_integer(), reaped: non_neg_integer()}}
  def write(%Scope{active_project_id: project_id} = scope, covered, nodes) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now()
    target = event_target()

    :telemetry.execute(DrainCost.projection_write(), %{count: 1}, %{project_id: project_id})

    # Read before the upsert, so a row it inserts is not counted as already there.
    Repo.transaction(fn ->
      existing = existing_rows(target, covered, working_copy_id)
      before = existing |> Enum.map(& &1.id) |> MapSet.new()
      before_by_key = Map.new(existing, &{{&1.entity_type, &1.owner_id, &1.name}, &1})

      written =
        nodes
        |> Enum.group_by(& &1.entity_type)
        |> Enum.flat_map(fn {entity_type, group} ->
          upsert_group(target, entity_type, group, before_by_key, working_copy_id, now)
        end)
        |> MapSet.new()

      # `written` only names rows that changed -- an unchanged row is covered
      # just the same, so it comes from the input.
      covered_ids =
        for node <- nodes,
            row = Map.get(before_by_key, {node.entity_type, node.entity_id, node.name}),
            not is_nil(row),
            do: row.id

      kept = MapSet.union(written, MapSet.new(covered_ids))

      departed = MapSet.difference(before, kept)
      delete_ids(MapSet.to_list(departed), target)

      %{inserted: MapSet.size(MapSet.difference(kept, before)), reaped: MapSet.size(departed)}
    end)
  end

  # A row is rewritten only when one of these moved; `checked_at` moves only
  # when the answer did, as in `sweep/2` (graph reads report it as `computed_at`).
  @compared [
    :satisfied,
    :details,
    :description,
    :inputs_fingerprint,
    :owner_component_type,
    :node_scope
  ]
  @verdict [:satisfied, :details]

  # Rows this vantage already holds are compared here and rewritten by id; new
  # ones are inserted. Returns the ids written, so departed rows are a subtraction.
  defp upsert_group(target, entity_type, nodes, before_by_key, working_copy_id, now) do
    {fresh, changed} =
      Enum.reduce(nodes, {[], []}, fn node, {fresh, changed} ->
        row = row(node, entity_type, node.entity_id, working_copy_id, now)

        case Map.get(before_by_key, {entity_type, node.entity_id, node.name}) do
          nil -> {[row | fresh], changed}
          old -> {fresh, rewrite(old, row, now) ++ changed}
        end
      end)

    # `:nothing` absorbs a concurrent drain that inserted the same row first.
    inserted = insert_rows(target, fresh, on_conflict: :nothing, returning: [:id])

    rewritten =
      insert_rows(target, changed,
        on_conflict: {:replace, @compared ++ [:checked_at, :updated_at]},
        conflict_target: [:id],
        returning: [:id]
      )

    inserted ++ rewritten
  end

  defp rewrite(old, row, now) do
    if Enum.any?(@compared, &(Map.get(old, &1) != comparable(&1, row))) do
      moved? = Enum.any?(@verdict, &(Map.get(old, &1) != comparable(&1, row)))
      [Map.merge(row, %{id: old.id, checked_at: if(moved?, do: now, else: old.checked_at)})]
    else
      []
    end
  end

  # `details` comes back from the database with string keys.
  defp comparable(:details, row), do: row.details |> Jason.encode!() |> Jason.decode!()
  defp comparable(field, row), do: Map.get(row, field)

  defp insert_rows(_target, [], _opts), do: []

  # Chunked by the bind budget divided by the row's own width.
  defp insert_rows(target, rows, opts) do
    rows
    |> Enum.chunk_every(div(@bind_budget, map_size(hd(rows))))
    |> Enum.flat_map(fn chunk ->
      {_n, returned} = Repo.insert_all(target, chunk, opts)
      Enum.map(returned, & &1.id)
    end)
  end

  # Every row the covered owners hold at this vantage, with its (owner, name)
  # key — the only rows a write may reap. Carries the key because an unchanged
  # row is absent from RETURNING (see `on_conflict/1`).
  defp existing_rows(target, covered, working_copy_id) do
    story_ids = for {"story", id} <- covered, do: id

    issue_ids =
      target
      |> where([n], not is_nil(n.issue_id))
      |> where(
        [n],
        n.issue_id in subquery(
          from(i in CodeMySpec.Issues.Issue, where: i.story_id in ^story_ids, select: i.id)
        ) or type(json_extract_path(n.details, ["story_id"]), :integer) in ^story_ids
      )
      |> where(^copy_filter(working_copy_id))
      |> select([n], n.issue_id)
      |> Repo.all()

    (Enum.to_list(covered) ++ Enum.map(issue_ids, &{"issue", &1}))
    |> Enum.uniq()
    |> Enum.group_by(fn {type, _id} -> type end, fn {_type, id} -> id end)
    |> Enum.flat_map(fn {entity_type, owner_ids} ->
      owner_ids
      |> Enum.chunk_every(@bind_budget)
      |> Enum.flat_map(fn ids ->
        target
        |> where(^owners_filter(entity_type, ids))
        |> where(^copy_filter(working_copy_id))
        |> select_existing(entity_type)
        |> Repo.all()
      end)
    end)
  end

  # What `upsert_group/6` compares against, keyed by owner.
  defp select_existing(query, entity_type) do
    owner = owner_field(entity_type)

    select(query, [n], %{
      id: n.id,
      name: n.name,
      owner_id: field(n, ^owner),
      entity_type: ^entity_type,
      satisfied: n.satisfied,
      details: n.details,
      description: n.description,
      inputs_fingerprint: n.inputs_fingerprint,
      owner_component_type: n.owner_component_type,
      node_scope: n.node_scope,
      checked_at: n.checked_at
    })
  end

  defp delete_ids([], _target), do: :ok

  defp delete_ids(ids, target) do
    ids
    |> Enum.chunk_every(@bind_budget)
    |> Enum.each(fn chunk -> target |> where([n], n.id in ^chunk) |> Repo.delete_all() end)
  end

  defp owners_filter("component", ids), do: dynamic([n], n.component_id in ^ids)
  defp owners_filter("issue", ids), do: dynamic([n], n.issue_id in ^ids)
  defp owners_filter("story", ids), do: dynamic([n], n.story_id in ^ids)
  defp owners_filter("project", ids), do: dynamic([n], n.project_id in ^ids)

  @doc """
  Set one requirement's verdict, without recomputing anything around it.

  What an event handler writes: the single row the event settled, siblings
  untouched (`write/3` is the recompute).

  `{:ok, 0}` when no row matched — the event named an entity this vantage has
  never projected (rows are created by seeding, never here). The caller counts
  misses.
  """
  @spec put_verdict(Scope.t(), map()) :: {:ok, non_neg_integer()}
  def put_verdict(%Scope{} = scope, change) do
    {count, _} =
      event_target()
      |> where(^owner_filter(change.entity_type, change.entity_id))
      |> where(^copy_filter(Projection.vantage(scope)))
      |> where([n], n.name == ^change.name)
      |> Repo.update_all(
        set: [
          satisfied: change.satisfied,
          details: change.details,
          checked_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        ]
      )

    {:ok, count}
  end

  @doc """
  Settle one requirement across every entity of a type, then the exceptions.

  What a set-based handler writes: one `UPDATE` for the default (every entity
  not named, e.g. stories triaged *by absence*) and one for the named
  exceptions (`put_verdicts/5`), in a transaction so a reader never sees the
  new default beside stale exceptions. The two halves are disjoint.

  Neither statement writes a row whose answer did not move (`IS DISTINCT FROM`),
  which keeps `checked_at` — and so `computed_at` on reads — still when nothing
  changed. See knowledge/requirements_graph, "Verdicts and handlers".

  Answers how many rows it actually wrote, not how many it matched.
  """
  @spec sweep(Scope.t(), map()) :: {:ok, non_neg_integer()}
  def sweep(%Scope{} = scope, %{entity_type: entity_type, name: name} = spec) do
    now = NaiveDateTime.utc_now()
    ids = Enum.map(spec.except, & &1.entity_id)

    {:ok, written} =
      Repo.transaction(fn ->
        {:ok, defaulted} = settle_default(scope, entity_type, name, spec, ids, now)
        {:ok, excepted} = put_verdicts(scope, entity_type, name, spec.except, now)

        defaulted + excepted
      end)

    {:ok, written}
  end

  # Every row of this requirement the exceptions did not name, where the answer
  # differs from the default.
  #
  # Must carry the project predicate: a default names no entity, and the nil
  # vantage is shared by every project, so without it a drain writes other
  # projects' rows. See knowledge/requirements_graph, "Lessons".
  defp settle_default(scope, entity_type, name, spec, ids, now) do
    owner = owner_field(entity_type)

    {rows, _} =
      event_target()
      |> where([n], n.name == ^name and not is_nil(field(n, ^owner)))
      |> where(^copy_filter(Projection.vantage(scope)))
      |> where(^project_filter(entity_type, scope.active_project_id))
      |> where([n], field(n, ^owner) not in ^ids)
      |> where(^verdict_differs(spec.default, spec.default_details))
      |> Repo.update_all(verdict_set(spec.default, spec.default_details, now))

    {:ok, rows}
  end

  # Which of these rows are this project's. Only project rows carry
  # `project_id`; other rows are asked of their owner's table.
  defp project_filter("project", project_id), do: dynamic([n], n.project_id == ^project_id)

  defp project_filter("component", project_id),
    do:
      dynamic(
        [n],
        n.component_id in subquery(
          from(c in CodeMySpec.Components.Component,
            where: c.project_id == ^project_id,
            select: c.id
          )
        )
      )

  defp project_filter("issue", project_id),
    do:
      dynamic(
        [n],
        n.issue_id in subquery(
          from(i in CodeMySpec.Issues.Issue, where: i.project_id == ^project_id, select: i.id)
        )
      )

  defp project_filter("story", project_id),
    do:
      dynamic(
        [n],
        n.story_id in subquery(from(s in Story, where: s.project_id == ^project_id, select: s.id))
      )

  # A row whose answer would not move is not written, which keeps `checked_at`
  # — and so `computed_at` on reads — still when nothing changed.
  defp verdict_differs(nil, details),
    do: dynamic([n], not is_nil(n.satisfied) or n.details != ^details)

  defp verdict_differs(satisfied, details),
    do: dynamic([n], is_nil(n.satisfied) or n.satisfied != ^satisfied or n.details != ^details)

  defp verdict_set(satisfied, details, now),
    do: [set: [satisfied: satisfied, details: details, checked_at: now, updated_at: now]]

  @doc """
  Correct many entities' verdicts for one requirement.

  The batch form of `put_verdict/2`: one `UPDATE` per distinct verdict, not one
  per entity.

  Answers how many rows changed. Settling never creates rows, so an entity this
  vantage has never projected is a miss the caller counts.
  """
  @spec put_verdicts(Scope.t(), String.t(), String.t(), [map()], NaiveDateTime.t()) ::
          {:ok, non_neg_integer()}
  def put_verdicts(scope, entity_type, name, changes, now \\ nil)

  def put_verdicts(%Scope{}, _entity_type, _name, [], _now), do: {:ok, 0}

  def put_verdicts(%Scope{} = scope, entity_type, name, changes, now) do
    now = now || NaiveDateTime.utc_now()
    vantage = Projection.vantage(scope)

    rows =
      changes
      |> Enum.group_by(&{&1.satisfied, &1.details}, & &1.entity_id)
      |> Enum.flat_map(fn {verdict, ids} ->
        Enum.map(Enum.chunk_every(ids, @bind_budget), &{verdict, &1})
      end)
      |> Enum.reduce(0, fn {{satisfied, details}, ids}, written ->
        {count, _} =
          event_target()
          |> where(^owners_filter(entity_type, ids))
          |> where([n], n.name == ^name)
          |> where(^copy_filter(vantage))
          |> where(^verdict_differs(satisfied, details))
          |> Repo.update_all(verdict_set(satisfied, details, now))

        written + count
      end)

    {:ok, rows}
  end

  @doc """
  Replace this vantage's whole topology with `edges`.

  The wanted set is whole because a transitive reduction is global; the write
  is a difference — stale edges deleted, new ones inserted, unchanged ones
  untouched. Only a drain that wrote or reaped nodes needs to call this.

  `ids` is the vantage's `node_ids/1`, when the caller already loaded it.
  An edge endpoint with no row is dropped. See knowledge/requirements_graph,
  "Edges".
  """
  @spec write_edges(Scope.t(), [%{from: tuple(), to: tuple()}], map() | nil) ::
          {:ok, non_neg_integer()}
  def write_edges(%Scope{active_project_id: project_id} = scope, edges, ids \\ nil) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now()

    # Resolved after this drain's node writes, so the ids are current.
    ids = ids || ids_by_owner_key(project_id, working_copy_id)

    # An endpoint with no row is not an edge.
    rows =
      edges
      |> Enum.uniq()
      |> Enum.flat_map(fn %{from: {ft, fi, fname}, to: {tt, ti, tname}} ->
        case {Map.get(ids, {ft, to_string(fi), fname}), Map.get(ids, {tt, to_string(ti), tname})} do
          {nil, _} ->
            []

          {_, nil} ->
            []

          {from_id, to_id} ->
            [%{from_requirement_id: from_id, to_requirement_id: to_id, inserted_at: now}]
        end
      end)

    # The difference, not the whole set: a full rewrite was ~250k row writes per
    # topology change. See knowledge/requirements_graph, "Edges".
    {:ok, count} =
      Repo.transaction(fn ->
        held = held_edges(Map.values(ids))
        wanted = MapSet.new(rows, &edge_identity/1)

        stale = for {identity, id} <- held, not MapSet.member?(wanted, identity), do: id
        fresh = Enum.reject(rows, &Map.has_key?(held, edge_identity(&1)))

        delete_edges(stale) + insert_edges(fresh)
      end)

    {:ok, count}
  end

  @doc """
  Every node this vantage holds, by the key an edge names it with, to its row
  id. What `write_edges/3` resolves edges through and what `present?/1` admits
  endpoints against — loaded once per redraw and handed to both.
  """
  @spec node_ids(Scope.t()) :: %{tuple() => integer()}
  def node_ids(%Scope{active_project_id: project_id} = scope),
    do: ids_by_owner_key(project_id, Projection.vantage(scope))

  @doc """
  Whether an edge endpoint has a row in `ids`, keyed the way `node_ids/1`
  keys them: the entity id as text, since a story's is an integer and the
  table stores the pair rather than pointing at a row.
  """
  @spec present?(map()) :: (tuple() -> boolean())
  def present?(ids),
    do: fn {type, id, name} -> Map.has_key?(ids, {type, to_string(id), name}) end

  # What this vantage already holds, by identity, compared in memory (a `NOT IN`
  # over tens of thousands would hit the bind limit). Edges carry no vantage
  # column; checking the `from` end against this vantage's node ids is enough,
  # since edges never cross vantages.
  defp held_edges([]), do: %{}

  defp held_edges(node_ids) do
    event_edges()
    |> where([e], e.from_requirement_id in ^node_ids)
    |> select([e], {e.id, e.from_requirement_id, e.to_requirement_id})
    |> Repo.all()
    |> Map.new(fn {id, from_id, to_id} -> {{from_id, to_id}, id} end)
  end

  defp delete_edges([]), do: 0

  defp delete_edges(ids) do
    ids
    |> Enum.chunk_every(@bind_budget)
    |> Enum.reduce(0, fn chunk, total ->
      {n, _} = event_edges() |> where([e], e.id in ^chunk) |> Repo.delete_all()
      total + n
    end)
  end

  # What makes two edges the same edge: the row ids it joins, not the entity
  # keys — a key match kept edges pointing at rows that no longer existed.
  defp edge_identity(row), do: {row.from_requirement_id, row.to_requirement_id}

  @doc """
  Whether this vantage has been projected at all.

  Asked of the project's own rows, which every seed writes. A settle asks this
  before trusting the marks: a checkout someone just read, with no mark naming
  it, would otherwise never be written. One indexed query.
  """
  @spec projected?(Scope.t()) :: boolean()
  def projected?(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    event_target()
    |> where([n], n.project_id == ^project_id)
    |> where(^copy_filter(Projection.vantage(scope)))
    |> Repo.exists?()
  end

  def projected?(%Scope{}), do: false

  @doc """
  Whether the rows at this vantage carry every requirement the templates
  define for the entities they cover, and nothing the templates no longer do.

  A vantage whose rows predate a definition (a release added or dropped a
  requirement) is seeded like one with no rows: handlers settle rows and never
  create them. Compared per entity type; no rows of a type is not a mismatch.
  See knowledge/requirements_graph, "Seeding".

  `defined` is `RequirementGraph.defined_names/2`. Component names are
  compared per owning type over parent- and self-scoped rows only, for the
  reason given there.
  """
  @spec definitions_covered?(Scope.t(), map()) :: boolean()
  def definitions_covered?(%Scope{active_project_id: project_id} = scope, defined)
      when is_binary(project_id) do
    {component_ids, story_ids} = entity_ids(project_id)

    held =
      event_target()
      |> scoped(project_id, component_ids, story_ids)
      |> where(^copy_filter(Projection.vantage(scope)))
      |> select(
        [n],
        {n.component_id, n.story_id, n.issue_id, n.owner_component_type, n.node_scope, n.name}
      )
      |> Repo.all()
      |> Enum.uniq()

    story_held =
      for {nil, story, nil, _t, _s, name} <- held, not is_nil(story), into: MapSet.new(), do: name

    project_held = for {nil, nil, nil, _t, _s, name} <- held, into: MapSet.new(), do: name

    component_held = component_definition_names(held)

    issue_held =
      for {nil, nil, issue, _t, _s, name} <- held, not is_nil(issue), into: MapSet.new(), do: name

    entity_coverage?(held, Map.get(defined, :entities)) and
      covered?(issue_held, Map.get(defined, :issue, MapSet.new(["submitted"]))) and
      covered?(story_held, defined.story) and covered?(project_held, defined.project) and
      component_definitions_covered?(component_held, defined.component)
  end

  def definitions_covered?(%Scope{}, _defined), do: true

  @doc "Entities whose persisted node membership differs from the current template."
  def incomplete_entities(%Scope{active_project_id: project_id} = scope, expected) do
    {component_ids, story_ids} = entity_ids(project_id)

    held =
      event_target()
      |> scoped(project_id, component_ids, story_ids)
      |> where(^copy_filter(Projection.vantage(scope)))
      |> select(
        [n],
        {n.component_id, n.story_id, n.issue_id, n.owner_component_type, n.node_scope, n.name}
      )
      |> Repo.all()

    mismatched_entities(held, expected)
  end

  defp entity_coverage?(_held, nil), do: true
  defp entity_coverage?(held, expected), do: MapSet.size(mismatched_entities(held, expected)) == 0

  defp mismatched_entities(held, expected) do
    actual =
      Enum.reduce(held, %{}, fn
        {component, nil, nil, _type, _scope, name}, acc when not is_nil(component) ->
          Map.update(acc, {"component", component}, MapSet.new([name]), &MapSet.put(&1, name))

        {nil, story, nil, _type, _scope, name}, acc when not is_nil(story) ->
          Map.update(acc, {"story", story}, MapSet.new([name]), &MapSet.put(&1, name))

        _project, acc ->
          acc
      end)

    (Map.keys(actual) ++ Map.keys(expected))
    |> Enum.filter(&(Map.get(actual, &1, MapSet.new()) != Map.get(expected, &1, MapSet.new())))
    |> MapSet.new()
  end

  defp component_definitions_covered?(held, defined) do
    Enum.all?(held, fn {type, names} ->
      case Map.fetch(defined, type) do
        {:ok, expected} -> covered?(names, expected)
        :error -> true
      end
    end)
  end

  defp component_definition_names(held) do
    held
    |> Enum.filter(fn {component, _story, _issue, _type, node_scope, _name} ->
      not is_nil(component) and node_scope in ["parent", "self"]
    end)
    |> Enum.group_by(fn {_c, _s, _i, type, _scope, _name} -> type end, fn {_c, _s, _i, _t, _scope,
                                                                           name} ->
      name
    end)
    |> Map.new(fn {type, names} -> {type, MapSet.new(names)} end)
  end

  # No rows of the type is not a mismatch: the vantage may hold no such
  # entity. Rows of the type carry exactly the defined names, or a release
  # moved between them and the rows.
  defp covered?(held, expected),
    do: MapSet.size(held) == 0 or MapSet.equal?(held, expected)

  @doc "Forget the rows projection for this vantage, so it rebuilds from scratch."
  @spec clear(Scope.t()) :: :ok
  def clear(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    {component_ids, story_ids} = entity_ids(project_id)

    event_target()
    |> scoped(project_id, component_ids, story_ids)
    |> where(^copy_filter(Projection.vantage(scope)))
    |> Repo.delete_all()

    :ok
  end

  def clear(%Scope{}), do: :ok

  # The project's entities, scoping reads the way `Projection.project_rows/3` does.
  defp entity_ids(project_id) do
    {Repo.all(from(c in Component, where: c.project_id == ^project_id, select: c.id)),
     Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id))}
  end

  defp scoped(source, project_id, component_ids, story_ids) do
    from(n in source,
      where:
        n.component_id in ^component_ids or n.story_id in ^story_ids or
          n.issue_id in subquery(
            from(i in CodeMySpec.Issues.Issue,
              where: i.project_id == ^project_id and i.story_id in ^story_ids,
              select: i.id
            )
          ) or
          n.project_id == ^project_id
    )
  end

  # The rows owned by one entity.
  defp owner_filter("component", id), do: dynamic([n], n.component_id == ^id)
  defp owner_filter("issue", id), do: dynamic([n], n.issue_id == ^id)
  defp owner_filter("story", id), do: dynamic([n], n.story_id == ^id)
  defp owner_filter("project", id), do: dynamic([n], n.project_id == ^id)

  # `is_nil` rather than `== nil`: `= NULL` is never true, so the unscoped
  # vantage would match no row.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  defp row(node, entity_type, entity_id, working_copy_id, now) do
    %{
      name: node.name,
      description: node.description || node.name,
      satisfied: node.satisfied,
      details: node.details || %{},
      checked_at: now,
      inputs_fingerprint: Map.get(node, :inputs_fingerprint),
      owner_component_type: Map.get(node, :owner_component_type),
      node_scope: node |> Map.get(:node_scope) |> scope_string(),
      inserted_at: now,
      updated_at: now,
      working_copy_id: working_copy_id
    }
    |> Map.put(owner_field(entity_type), entity_id)
  end

  defp owner_field("component"), do: :component_id
  defp owner_field("issue"), do: :issue_id
  defp owner_field("story"), do: :story_id
  defp owner_field("project"), do: :project_id

  defp scope_string(nil), do: nil
  defp scope_string(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_string(scope) when is_binary(scope), do: scope

  # Chunked by the bind budget divided by the row's own width, measured rather
  # than hard-coded: a constant went stale when a column was added.
  defp insert_edges([]), do: 0

  # `on_conflict: :nothing` on the pair of ends makes a concurrent drain's
  # duplicate harmless.
  defp insert_edges([row | _] = rows) do
    rows
    |> Enum.chunk_every(div(@bind_budget, map_size(row)))
    |> Enum.reduce(0, fn chunk, total ->
      inserted =
        Repo.insert_all(event_edges(), chunk,
          on_conflict: :nothing,
          conflict_target: [:from_requirement_id, :to_requirement_id]
        )

      total + elem(inserted, 0)
    end)
  end

  # Every node at this vantage, by the `{type, id-as-text, name}` key edge ends use.
  defp ids_by_owner_key(project_id, working_copy_id) do
    {component_ids, story_ids} = entity_ids(project_id)

    event_target()
    |> scoped(project_id, component_ids, story_ids)
    |> where(^copy_filter(working_copy_id))
    |> select([n], {n.id, n.component_id, n.story_id, n.project_id, n.issue_id, n.name})
    |> Repo.all()
    |> Map.new(fn {id, component_id, story_id, proj_id, issue_id, name} ->
      {owner_key(component_id, story_id, proj_id, issue_id, name), id}
    end)
  end

  # `entity_id` as text: a component's is a uuid and a story's a bigint.
  defp owner_key(component_id, _story, _project, _issue, name) when not is_nil(component_id),
    do: {"component", component_id, name}

  defp owner_key(_component, story_id, _project, _issue, name) when not is_nil(story_id),
    do: {"story", to_string(story_id), name}

  defp owner_key(_component, _story, _project, issue_id, name) when not is_nil(issue_id),
    do: {"issue", issue_id, name}

  defp owner_key(_component, _story, project_id, _issue, name),
    do: {"project", project_id, name}
end
