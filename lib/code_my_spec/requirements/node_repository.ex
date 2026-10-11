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
  anything. `requirement_details/3` is one such reader; the recompute path
  exists to keep the rows true, not to answer every question about them.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Node, Projection, Requirement, Shadow}
  alias CodeMySpec.Users.Scope

  # a69525bd / 181f3469: a row EXCLUDED agrees with on every stored column is
  # left alone rather than rewritten -- reaping here is already independent
  # of what this upsert touches (`delete_departed/4` re-queries `ids_by_key`
  # rather than trusting RETURNING), so the guard is safe to add outright.
  defp on_conflict({_table, _schema} = target) do
    from(n in target,
      update: [
        set: [
          satisfied: fragment("EXCLUDED.satisfied"),
          details: fragment("EXCLUDED.details"),
          description: fragment("EXCLUDED.description"),
          checked_at: fragment("EXCLUDED.checked_at"),
          inputs_fingerprint: fragment("EXCLUDED.inputs_fingerprint"),
          owner_component_type: fragment("EXCLUDED.owner_component_type"),
          node_scope: fragment("EXCLUDED.node_scope"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where:
        fragment(
          "? IS DISTINCT FROM EXCLUDED.satisfied OR ? IS DISTINCT FROM EXCLUDED.details OR ? IS DISTINCT FROM EXCLUDED.description OR ? IS DISTINCT FROM EXCLUDED.inputs_fingerprint OR ? IS DISTINCT FROM EXCLUDED.owner_component_type OR ? IS DISTINCT FROM EXCLUDED.node_scope",
          n.satisfied,
          n.details,
          n.description,
          n.inputs_fingerprint,
          n.owner_component_type,
          n.node_scope
        )
    )
  end

  @doc """
  Satisfied and total requirement rows for one story, read at one working copy.

  A placed story's rows exist only at the copy it is reserved for
  (`Projection.placed/2`), so that copy is the one to name.
  """
  @spec story_progress(integer(), Ecto.UUID.t() | nil) :: {non_neg_integer(), non_neg_integer()}
  def story_progress(story_id, working_copy_id) do
    Node
    |> where([n], n.story_id == ^story_id)
    |> at_copy(working_copy_id)
    |> select([n], {filter(count(n.id), n.satisfied), count(n.id)})
    |> Repo.one()
  end

  defp at_copy(query, nil), do: where(query, [n], is_nil(n.working_copy_id))
  defp at_copy(query, copy_id), do: where(query, [n], n.working_copy_id == ^copy_id)

  @doc """
  One requirement's recorded `details`, read straight off the row.

  For the stop hook's nudge, which wants a single reason string and used to get
  it by asking for the whole graph — `Requirements.cached_all/1`, which computes
  the project on a cache miss. The stop hook syncs files before it decides, so
  the fingerprint has always just moved and the miss is the normal case: a full
  compute, edges included, to read one `details["reason"]` the row already
  holds. Measured on this project after the incremental recompute shipped, four
  computes in nine minutes on the new build, two of them stop hooks.

  A stop is not a change. Nothing here recomputes.

  Scoped three ways because the rows are, deliberately: `project_id` is set
  only on project-level nodes, so filtering on it alone finds the handful and
  misses every component and story requirement.
  """
  @spec requirement_details(Scope.t(), String.t(), [String.t()]) :: map() | nil
  def requirement_details(%Scope{active_project_id: nil}, _name, _entity_ids), do: nil

  def requirement_details(%Scope{}, _name, []), do: nil

  def requirement_details(%Scope{active_project_id: project_id} = scope, name, entity_ids) do
    wanted = Enum.map(entity_ids, &to_string/1)

    from(n in Node,
      where: n.name == ^to_string(name),
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
          ),
      select: %{
        details: n.details,
        project_id: n.project_id,
        component_id: n.component_id,
        story_id: n.story_id
      }
    )
    |> where(^copy_filter(Projection.vantage(scope)))
    |> Repo.all()
    |> Enum.find(fn row ->
      # All three, because a row names its entity in exactly one of them and
      # leaves the other two null — a project requirement carries `project_id`
      # and no component or story. Matching only the latter two answered "no
      # reason" for every project-level requirement, which is how the nudge
      # went back to naming `technical_strategy` without saying what held it.
      to_string(row.project_id) in wanted or
        to_string(row.component_id) in wanted or
        to_string(row.story_id) in wanted
    end)
    |> case do
      %{details: details} -> details
      nil -> nil
    end
  end

  @doc """
  Persist computed nodes, returning them keyed by `Topology.node_key/1`.

  The map is the point: it is how an edge turns a `{entity_type, entity_id, name}`
  pair into the two row ids it needs.
  """
  @spec upsert_all(Scope.t(), [Requirement.t()], visited()) :: %{tuple() => integer()}
  def upsert_all(%Scope{active_project_id: project_id} = scope, nodes, visited \\ nil)
      when is_list(nodes) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Whose view this computation is. `Preloader.load/1` scoped its file query
    # to this copy, so every verdict below is a statement about what this
    # checkout could see — and writing it without saying so is what let any
    # checkout overwrite the project's whole graph.
    #
    # `Projection.vantage/1`, not the raw field: a caller with no checkout to
    # name (`active_working_copy_id: nil` — the UI path) reads back through
    # `vantage/1`, which resolves that to the project's default working copy
    # whenever one is set. Writing under the raw `nil` instead persisted every
    # UI-triggered publish somewhere `Projection.load/2` would never look again
    # once a project had a default working copy — a permanent, silent miss
    # (`verify_round_trip` logging "the projection does not round-trip" on
    # every single publish, forever; `RequirementGraph.served_graph/3`'s guard
    # refusing every cache hit as a result — cc4745dc). `vantage/1` only ever
    # answers something other than the raw field for that one caller shape, so
    # a scope that already names a checkout persists exactly where it always
    # did.
    working_copy_id = Projection.vantage(scope)

    nodes
    |> Enum.group_by(& &1.entity_type)
    |> Enum.each(fn {entity_type, group} ->
      upsert_group(entity_type, group, working_copy_id, now)
    end)

    keys = ids_by_key(project_id, working_copy_id, nodes)
    delete_departed(scope, working_copy_id, visited || from_nodes(nodes), keys)
    keys
  end

  @typedoc """
  Which entities this computation looked at, as against which produced nodes.

  The two differ, and conflating them is what let stale rows survive forever.
  """
  @type visited :: %{components: [Ecto.UUID.t()], stories: [integer()]} | nil

  defp from_nodes(nodes) do
    %{components: entity_ids(nodes, "component"), stories: entity_ids(nodes, "story")}
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
  #
  # "Covered" is what the computation *looked at*, not what it *produced*, and
  # deriving it from the produced nodes conflated two different things: a
  # component nobody loaded, and a component that was loaded and yielded
  # nothing. Only the first should keep its rows.
  #
  # The second is ordinary: `graph_for_type("infrastructure")` is `[]`, so an
  # infrastructure-typed component computes nothing at all. There are 11 of them
  # on this project. Absent from the produced set, each is read as "not visited"
  # and keeps whatever rows it had from before it was retyped — for good, since
  # nothing will ever visit-and-produce for it again.
  #
  # ## Correction, and it matters because the first version of this comment was
  # ## wrong
  #
  # This originally said `schema_graph/0` was `spec_file` and `spec_valid` only,
  # so schema components computed nothing under `require_specs: false`, and that
  # 84 of them held `implementation_file` rows their type no longer defined.
  # That is false. `schema_graph/0` defines `implementation_file` — it is the
  # third entry, and `git log -S` shows it unbroken since `a5a7a1fd3`. I read
  # the head of the function and stopped.
  #
  # So schema components *do* produce a node, *are* in the produced set, and
  # were always reaped correctly. They were never an instance of this bug.
  #
  # The change stands on the distinction itself, which is real — a component
  # that computes nothing is not a component nobody looked at — and on the
  # infrastructure case above. It does **not** explain the 2009-against-1844
  # short read on cc4745dc, and the earlier claim that it did was built on the
  # same misreading.
  defp delete_departed(%Scope{active_project_id: project_id}, working_copy_id, visited, keys) do
    keep = keys |> Map.values() |> MapSet.new()

    %{components: component_ids, stories: story_ids} = visited

    Shadow.pass_target()
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id or
        n.story_id in subquery(parked_story_ids(project_id))
    )
    # And only this copy's rows. Without it, one checkout syncing would treat
    # every other checkout's nodes as departed and delete them — the same
    # overwrite this change exists to stop, arriving as a reap instead of a
    # write.
    |> where(^copy_filter(working_copy_id))
    |> select([n], n.id)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> case do
      [] -> :ok
      ids -> Shadow.pass_target() |> where([n], n.id in ^ids) |> Repo.delete_all()
    end
  end

  # Stories that are not released, whose rows are departed whoever was visited.
  #
  # `Preloader` loads only `ready_for_dev` stories, on purpose — a parked story
  # that projected would surface as actionable work nobody released. The cost of
  # that filter lands here: rows the story published while it *was* ready stay
  # in the table, and `Projection.rehydrate/2` cannot resolve them to an entity
  # any more, so it drops them. The read is then a strict subset of what the
  # publish counted, `served_graph/3` refuses the short read, and the graph
  # recomputes in full — on every read, for as long as the story stays parked.
  # Measured on the live database: 63 rows across 8 parked stories on one
  # project.
  #
  # Asked here rather than by widening `visited/1`, and the distinction matters.
  # `visited` is built from the context, which on an incremental pass is
  # deliberately narrowed to the stale entities — so a story absent from it may
  # simply not have been this pass's business, and reaping on that basis would
  # delete live rows. "This story is not released" is true regardless of what
  # the pass was looking at, which makes it safe on a full pass and a narrow one
  # alike.
  defp parked_story_ids(project_id) do
    from(s in CodeMySpec.Stories.Story,
      where: s.project_id == ^project_id and s.ready_for_dev == false,
      select: s.id
    )
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

      insert_every(Shadow.pass_edges(), stamp(rows),
        on_conflict: :nothing,
        conflict_target: [:from_requirement_id, :to_requirement_id]
      )
    end)
  end

  defp stamp(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    Enum.map(rows, &Map.put(&1, :inserted_at, now))
  end

  # Postgres binds one parameter per column per row, and the wire protocol
  # counts them in a 16-bit field: 65535 for the whole statement, no matter how
  # the rows are shaped. An `insert_all` that crosses it does not get slower, it
  # refuses — "postgresql protocol can not handle 71982 parameters, the maximum
  # is 65535" — before touching the database.
  #
  # Which made it a livelock rather than a failed write. The recompute that
  # produced those rows stores nothing, so the next read finds the graph stale
  # and computes it again, and fails again, forever: 44 failures and 54 full
  # recomputes in 45 minutes.
  #
  # Per vantage rather than per project, which is what hid it. Rows are scoped
  # to a working copy, so a project holds one graph per checkout and only the
  # widest crosses the limit — four checkouts of the project this was found on
  # sat at 9,346 to 14,571 edges and reused their rows normally, while the
  # fifth at 23,994 had never once managed to write any. Both were logged side
  # by side, so the partial-recompute count looked healthy the whole time.
  # 71982 is that fifth graph exactly: 23,994 edges at three columns.
  #
  # Chunked on the row's own width rather than a fixed row count, so a column
  # added to either table cannot quietly walk the limit back under us. The
  # budget leaves headroom against the hard cap for the same reason.
  # Overridable so the chunking can be tested by crossing a boundary at four
  # rows instead of twenty thousand. A test that has to build a graph the size
  # of the one that broke is a test nobody runs.
  @default_bind_budget 60_000

  defp bind_budget,
    do: Application.get_env(:code_my_spec, :bind_budget, @default_bind_budget)

  defp insert_every(_schema, [], _opts), do: 0

  defp insert_every(schema, rows, opts) do
    per_row = rows |> hd() |> map_size() |> max(1)

    rows
    |> Enum.chunk_every(max(div(bind_budget(), per_row), 1))
    |> Enum.reduce(0, fn chunk, total ->
      {count, _} = Repo.insert_all(schema, chunk, opts)
      total + count
    end)
  end

  # Only edges among *this* graph's nodes are ours to remove. Deleting by
  # project would take edges belonging to nodes this computation did not
  # produce, and there is no project column here to do it with anyway.
  # Both endpoints, not just the source.
  #
  # `keep` holds only the edges whose *both* ends resolved in `ids_by_key`, and
  # a partial recompute resolves ids for the nodes it recomputed and no others.
  # Filtering on `from` alone therefore deleted every edge leading out of a
  # recomputed node into a kept one: its `from` matched, and it could never be
  # in `keep` because its `to` was never resolved.
  #
  # Reported honestly by `verify_round_trip/4` from the first partial recompute
  # onward — "13788 edges only in the payload" — and I explained it away twice
  # before reading this function. Full recomputes kept restoring the edges, so
  # the stored totals looked right between partials and hid it.
  #
  # A write owns what it can rewrite. A partial write can rewrite the edges
  # between the nodes it recomputed, so those are the only ones it may delete.
  defp delete_edges_outside(node_ids, keep) do
    keep_pairs = MapSet.new(keep, &{&1.from_requirement_id, &1.to_requirement_id})
    owned = MapSet.new(node_ids)

    # `in ^list` binds one parameter per element, so both of these are the
    # insert's failure mode wearing a different shape — latent rather than
    # hypothetical, since the list is a whole graph's worth either way.
    node_ids
    |> Enum.chunk_every(bind_budget())
    |> Enum.flat_map(fn ids ->
      Shadow.pass_edges()
      |> where([e], e.from_requirement_id in ^ids)
      |> select([e], {e.id, e.from_requirement_id, e.to_requirement_id})
      |> Repo.all()
    end)
    |> Enum.reject(fn {_id, from, to} ->
      MapSet.member?(keep_pairs, {from, to}) or not MapSet.member?(owned, to)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(bind_budget())
    |> Enum.each(fn ids ->
      Shadow.pass_edges() |> where([e], e.id in ^ids) |> Repo.delete_all()
    end)
  end

  # Stored as a string because the column is one. `nil` stays nil, which
  # `Projection` reads as "written before this existed" and infers for.
  defp scope_string(nil), do: nil
  defp scope_string(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_string(scope) when is_binary(scope), do: scope

  defp upsert_group(entity_type, nodes, working_copy_id, now) do
    {owner_field, conflict_target} = owner(entity_type)

    entries =
      Enum.map(nodes, fn node ->
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
        |> Map.put(owner_field, node.entity_id)
      end)

    # Ten columns a row, so this one refuses at 6,553 nodes rather than the
    # edge table's 21,845 — the narrower limit of the two, and the one nothing
    # would have found first because edges outnumber nodes.
    target = Shadow.pass_target()

    insert_every(target, entries,
      on_conflict: on_conflict(target),
      conflict_target: conflict_target
    )
  end

  # Only the owner column is set: `Map.put(owner_field, entity_id)` puts a
  # project node's id in `project_id` and a component node's in `component_id`,
  # leaving the others null. That is what keeps the three partial indexes
  # disjoint — a component node carrying `project_id` would land in two of them.

  # The working copy is part of the identity now, so it is part of every
  # conflict target. An upsert naming only (owner, name) would still find the
  # other copy's row and replace its verdict — which is the defect, expressed as
  # an inference clause.
  defp owner("component"),
    do:
      {:component_id,
       {:unsafe_fragment, "(component_id, name, working_copy_id) WHERE component_id IS NOT NULL"}}

  defp owner("story"),
    do:
      {:story_id,
       {:unsafe_fragment, "(story_id, name, working_copy_id) WHERE story_id IS NOT NULL"}}

  defp owner("project"),
    do:
      {:project_id,
       {:unsafe_fragment, "(project_id, name, working_copy_id) WHERE project_id IS NOT NULL"}}

  # `is_nil` rather than `== nil`: the UI path's rows carry a null working copy,
  # and `= NULL` is never true in SQL, so comparing that way would match no row
  # and make every UI render insert a fresh duplicate.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  # Read back rather than trusting `insert_all`'s returning: an upsert that
  # conflicted returns the existing row, and the ids have to be the same ones
  # edges will reference either way.
  @doc """
  The stored id of each of these nodes, keyed by `{entity_type, entity_id, name}`.

  For a partial pass that rebuilt the edge set. `upsert_all/3` already answers
  this for the nodes it wrote, and that is the narrow half — a pass drawing
  edges over the whole graph has to resolve the nodes it *kept* as well, or
  `replace_edges/3` drops every edge touching one and deletes the rest.

  Reads, writes nothing, and takes no view of its own on which rows exist: a
  node with no row is simply absent from the result, which is what
  `replace_edges/3` already expects of a key it cannot resolve.
  """
  @spec ids_for(Scope.t(), [Requirement.t()]) :: %{{String.t(), term(), String.t()} => term()}
  def ids_for(%Scope{active_project_id: project_id} = scope, nodes) when is_list(nodes) do
    ids_by_key(project_id, Projection.vantage(scope), nodes)
  end

  defp ids_by_key(project_id, working_copy_id, nodes) do
    names = nodes |> Enum.map(& &1.name) |> Enum.uniq()

    component_ids = entity_ids(nodes, "component")
    story_ids = entity_ids(nodes, "story")

    Shadow.pass_target()
    |> where([n], n.name in ^names)
    |> where(
      [n],
      n.component_id in ^component_ids or n.story_id in ^story_ids or
        n.project_id == ^project_id
    )
    # This copy's rows only. `{entity_type, entity_id, name}` stopped
    # identifying a row the moment there is one per copy, so without this
    # `Map.new/2` keeps whichever the database returned last and every edge is
    # built against an arbitrary checkout's node ids — silently, and only under
    # concurrency.
    |> where(^copy_filter(working_copy_id))
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
