defmodule CodeMySpec.Requirements.GraphStore do
  @moduledoc """
  Reads and writes the requirement graph's rows, for the event projection.

  `IncrementalGraph` decides what each entity's requirements are; this is where
  the record verdicts land, once per project in `project_requirements`
  (`project_wide_names/0`), and the project's edges in `requirement_topologies`.
  A checkout's file verdicts and placement gates are not stored: they are read
  (`CopyGraph`). Writes are per entity and per event: `write/3`
  replaces what one computation covered, `put_verdict/2` and `put_verdicts/5`
  move a verdict a handler already knew, `sweep/2` settles one requirement
  across every owner of a type, and `write_topology/4` stores the project's
  edges. The projection checks —
  `projected?/1`, `definitions_covered?/2`, `incomplete_entities/2` — tell the
  projector when the project's rows cannot be trusted and must be seeded.
  """

  import Ecto.Query, only: [from: 2, where: 2, where: 3, dynamic: 2, select: 3]

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.ProjectTopology
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  # Postgres caps a statement at 65,535 bind parameters (one per column per row).
  # Declared before any user: a module attribute read above its definition is `nil`.
  @bind_budget 60_000

  @project_table {"project_requirements", Node}

  # Verdicts that read only the project's records, or every checkout's files
  # (`personas_complete`): the same at every checkout, so stored once per
  # project. The rest read one checkout's files, or, like `issues_triaged`,
  # `issues_resolved` and `work_dispatched`, leave out issues on stories placed
  # at another checkout, and are read for each checkout, never stored.
  # `project_wide_names_test` derives this from the definitions' checkers.
  @project_wide ~w(
    component_linked three_amigos_complete questions_answered story_issues_triaged
    ready_for_qa qa_complete story_promoted deploy dependencies_met submitted
    qa_setup qa_journey_plan stories_exist personas_complete
  )

  # Every `Node` field the project table has: all but `working_copy_id`.
  @fields [
    :id,
    :name,
    :description,
    :satisfied,
    :details,
    :checked_at,
    :inputs_fingerprint,
    :owner_component_type,
    :node_scope,
    :component_id,
    :story_id,
    :issue_id,
    :project_id,
    :inserted_at,
    :updated_at
  ]

  @doc "The requirement names stored: once per project."
  @spec project_wide_names() :: [String.t()]
  def project_wide_names, do: @project_wide

  @doc "The rows stored once per project, as `Node`s."
  @spec project_rows() :: Ecto.Query.t()
  def project_rows, do: from(@project_table, select: ^@fields)

  @type entity :: {String.t(), term()}

  @doc """
  Replace the graph rows for everything this computation covered.

  Rows are written by each node's own owner and reaped by `covered`, which are
  separate inputs: a component family is computed together and a member can
  legitimately produce nothing, so "this component now has no requirements" has
  to reap its old rows.

  Upsert then reap, never delete-then-insert: a row keeps its id.

  Answers how many rows arrived and how many departed.
  """
  @spec write(Scope.t(), Enumerable.t(), [map()]) ::
          {:ok, %{inserted: non_neg_integer(), reaped: non_neg_integer()}}
  def write(%Scope{active_project_id: project_id}, covered, nodes) do
    now = NaiveDateTime.utc_now()
    # A copy's file verdicts are its overlay and its placement gates are settled
    # on read: only record verdicts are stored.
    project_nodes = Enum.filter(nodes, &(&1.name in @project_wide))

    :telemetry.execute(DrainCost.projection_write(), %{count: 1}, %{project_id: project_id})

    Repo.transaction(fn -> write_at(@project_table, covered, project_nodes, now) end)
  end

  # Read before the upsert, so a row it inserts is not counted as already there.
  defp write_at(target, covered, nodes, now) do
    existing = existing_rows(target, covered)
    before = existing |> Enum.map(& &1.id) |> MapSet.new()
    before_by_key = Map.new(existing, &{{&1.entity_type, &1.owner_id, &1.name}, &1})

    written =
      nodes
      |> Enum.group_by(& &1.entity_type)
      |> Enum.flat_map(fn {entity_type, group} ->
        upsert_group(target, entity_type, group, before_by_key, now)
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

  # Rows already held are compared here and rewritten by id; new
  # ones are inserted. Returns the ids written, so departed rows are a subtraction.
  defp upsert_group(target, entity_type, nodes, before_by_key, now) do
    {fresh, changed} =
      Enum.reduce(nodes, {[], []}, fn node, {fresh, changed} ->
        row = row(node, entity_type, node.entity_id, now)

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

  # Every row the covered owners hold here, with its (owner, name) key — the
  # only rows a write may reap. Carries the key because an unchanged row is
  # absent from RETURNING (see `on_conflict/1`).
  defp existing_rows(target, covered) do
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

  `{:ok, 0}` when no row matched — the event named an entity the project has
  never projected (rows are created by seeding, never here). The caller counts
  misses.
  """
  @spec put_verdict(Scope.t(), map()) :: {:ok, non_neg_integer()}
  def put_verdict(%Scope{}, change) do
    {count, _} =
      @project_table
      |> where(^owner_filter(change.entity_type, change.entity_id))
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
  # Must carry the project predicate: a default names no entity, and the table
  # is shared by every project, so without it a drain writes other projects'
  # rows. See knowledge/requirements_graph, "Lessons".
  defp settle_default(scope, entity_type, name, spec, ids, now) do
    owner = owner_field(entity_type)

    {rows, _} =
      @project_table
      |> where([n], n.name == ^name and not is_nil(field(n, ^owner)))
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
  project has never projected is a miss the caller counts.
  """
  @spec put_verdicts(Scope.t(), String.t(), String.t(), [map()], NaiveDateTime.t()) ::
          {:ok, non_neg_integer()}
  def put_verdicts(scope, entity_type, name, changes, now \\ nil)

  def put_verdicts(%Scope{}, _entity_type, _name, [], _now), do: {:ok, 0}

  def put_verdicts(%Scope{}, entity_type, name, changes, now) do
    now = now || NaiveDateTime.utc_now()

    # The stored verdicts first, so only rows that moved are written: most
    # exceptions carry their own details, and one `UPDATE` each was most of a
    # drain's queries.
    stored = stored_verdicts(entity_type, name, Enum.map(changes, & &1.entity_id))

    rows =
      changes
      |> Enum.reject(&(Map.get(stored, &1.entity_id) == {&1.satisfied, comparable(:details, &1)}))
      |> Enum.group_by(&{&1.satisfied, &1.details}, & &1.entity_id)
      |> Enum.flat_map(fn {verdict, ids} ->
        Enum.map(Enum.chunk_every(ids, @bind_budget), &{verdict, &1})
      end)
      |> Enum.reduce(0, fn {{satisfied, details}, ids}, written ->
        {count, _} =
          @project_table
          |> where(^owners_filter(entity_type, ids))
          |> where([n], n.name == ^name)
          |> where(^verdict_differs(satisfied, details))
          |> Repo.update_all(verdict_set(satisfied, details, now))

        written + count
      end)

    {:ok, rows}
  end

  defp stored_verdicts(entity_type, name, ids) do
    owner = owner_field(entity_type)

    ids
    |> Enum.chunk_every(@bind_budget)
    |> Enum.flat_map(fn chunk ->
      @project_table
      |> where(^owners_filter(entity_type, chunk))
      |> where([n], n.name == ^name)
      |> select([n], {field(n, ^owner), n.satisfied, n.details})
      |> Repo.all()
    end)
    |> Map.new(fn {id, satisfied, details} -> {id, {satisfied, details}} end)
  end

  @doc """
  The topology hash the project's stored edges were drawn from, or nil when it
  has none: a project with no row is unprojected.
  """
  @spec topology(Ecto.UUID.t()) :: String.t() | nil
  def topology(project_id) do
    Repo.one(from(t in ProjectTopology, where: t.project_id == ^project_id, select: t.topology))
  end

  @doc """
  Store the project's edges, drawn from `topology`, with the reduction views
  draw. One row per project: every checkout shares the edges and reads its
  share (`Edges.among/2`). See knowledge/requirements_graph, "Edges".
  """
  @spec write_topology(Ecto.UUID.t(), String.t(), [map()], [map()]) :: :ok
  def write_topology(project_id, topology, edges, display_edges) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ProjectTopology{
        project_id: project_id,
        topology: topology,
        edges: :erlang.term_to_binary(edges, [:compressed]),
        display_edges: :erlang.term_to_binary(display_edges, [:compressed]),
        inserted_at: now,
        updated_at: now
      },
      on_conflict: {:replace, [:topology, :edges, :display_edges, :updated_at]},
      conflict_target: :project_id
    )

    :ok
  end

  @doc "The project's edges as generated, or none when it has no row."
  @spec edges(Ecto.UUID.t()) :: [map()]
  def edges(project_id), do: read_edges(project_id, :edges)

  @doc "The project's edges reduced for drawing, or none when it has no row."
  @spec display_edges(Ecto.UUID.t()) :: [map()]
  def display_edges(project_id), do: read_edges(project_id, :display_edges)

  defp read_edges(project_id, field) do
    from(t in ProjectTopology, where: t.project_id == ^project_id, select: field(t, ^field))
    |> Repo.one()
    |> case do
      nil -> []
      binary -> :erlang.binary_to_term(binary, [:safe])
    end
  end

  @doc """
  Whether this project has been projected at all: its own rows, which every
  seed writes. One indexed query.
  """
  @spec projected?(Scope.t()) :: boolean()
  def projected?(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    @project_table
    |> where([n], n.project_id == ^project_id)
    |> Repo.exists?()
  end

  def projected?(%Scope{}), do: false

  @doc """
  Whether the project's rows carry every stored requirement the templates
  define for the entities they cover, and nothing the templates no longer do.

  A project whose rows predate a definition (a release added or dropped a
  requirement) is seeded like one with no rows: handlers settle rows and never
  create them. Compared per entity type; no rows of a type is not a mismatch.
  See knowledge/requirements_graph, "Seeding".

  `defined` is `RequirementGraph.defined_names/2`. Component names are
  compared per owning type over parent- and self-scoped rows only, for the
  reason given there.
  """
  @spec definitions_covered?(Scope.t(), map()) :: boolean()
  def definitions_covered?(%Scope{active_project_id: project_id}, defined)
      when is_binary(project_id) do
    held = project_id |> held() |> Enum.uniq()
    defined = stored_only(defined)

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
  def incomplete_entities(%Scope{active_project_id: project_id}, expected) do
    project_id |> held() |> mismatched_entities(stored_names(expected))
  end

  # The project's rows for its components and ready stories.
  defp held(project_id) do
    {component_ids, _story_ids} = entity_ids(project_id)

    ready =
      Repo.all(
        from(s in Story,
          where: s.project_id == ^project_id and s.ready_for_dev == true,
          select: s.id
        )
      )

    @project_table
    |> scoped(project_id, component_ids, ready)
    |> select(
      [n],
      {n.component_id, n.story_id, n.issue_id, n.owner_component_type, n.node_scope, n.name}
    )
    |> Repo.all()
  end

  # What the templates define, narrowed to what is stored: record verdicts.
  defp stored_only(defined) do
    defined
    |> Map.new(fn
      {:component, by_type} -> {:component, Map.new(by_type, fn {t, n} -> {t, stored(n)} end)}
      {:entities, entities} -> {:entities, stored_names(entities)}
      {key, names} -> {key, stored(names)}
    end)
  end

  defp stored_names(nil), do: nil
  defp stored_names(entities), do: Map.new(entities, fn {key, names} -> {key, stored(names)} end)

  defp stored(names), do: MapSet.intersection(MapSet.new(names), MapSet.new(@project_wide))

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

  # No rows of the type is not a mismatch: the project may hold no such
  # entity. Rows of the type carry exactly the defined names, or a release
  # moved between them and the rows.
  defp covered?(held, expected),
    do: MapSet.size(held) == 0 or MapSet.equal?(held, expected)

  @doc "Forget the project's rows, so it rebuilds from scratch."
  @spec clear(Scope.t()) :: :ok
  def clear(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    {component_ids, story_ids} = entity_ids(project_id)

    @project_table
    |> scoped(project_id, component_ids, story_ids)
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

  defp row(node, entity_type, entity_id, now) do
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
      updated_at: now
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
end
