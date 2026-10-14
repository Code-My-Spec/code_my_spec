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

  # Postgres binds one parameter per column per row and counts them in a 16-bit
  # field. Declared here rather than beside its first user, because a module
  # attribute is read at the point of use during compilation: defined lower down,
  # it was `nil` in `delete_edges_outside/3` and `chunk_every/2` raised.
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

  `covered` and the nodes' own owners are deliberately separate inputs.
  `RequirementGraph.compute_entity/4` answers for a component's whole family —
  a context's template produces its children's rows, so they cannot be computed
  apart from it — and within that family a member can legitimately produce
  nothing. Reaping by `covered` and writing by each node's own owner is what
  makes "this component now has no requirements" expressible; keying both sides
  off the nodes would leave that component's old rows standing forever.

  ## Upsert then reap, because a row id is referenced

  This deleted every covered row and inserted fresh ones, which reads as the
  narrower operation and is not: an inserted row gets a **new id**, and
  `write_edges/2` stores `from_requirement_id` and `to_requirement_id`. So every
  edge touching a rewritten node pointed at a row that no longer existed, and
  `edge_keys/6` — which resolves an edge through its own node table — could not
  resolve it. The edge was still in the table and gone from the graph.

  Measured 2026-09-17, on a project with 27 edges: creating a component through
  the real surface dropped the rows' resolvable topology to 12 while the pass
  went to 33. It was invisible for as long as it existed because `log/1`
  reported node counts only, and only reprojecting topology in the same drain
  put the ids back — so a verdict-only drain orphaned edges permanently.

  `NodeRepository.upsert_all/3` has always done this properly for the real
  table, on the same three partial unique indexes this table carries. After the
  swap the event path inherits that writer, so the delete-then-insert version
  would not have fixed itself by flipping the flag.
  """
  @spec write(Scope.t(), Enumerable.t(), [map()]) ::
          {:ok, %{inserted: non_neg_integer(), reaped: non_neg_integer()}}
  def write(%Scope{active_project_id: project_id} = scope, covered, nodes) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    target = event_target()

    :telemetry.execute(DrainCost.projection_write(), %{count: 1}, %{project_id: project_id})

    # Answers how the node set moved — rows that did not exist before and rows
    # that departed — because edges are a function of the node set and the
    # caller has to know whether to redraw them. A story whose rows arrive a
    # drain after the shape first showed it is otherwise never wired in: the
    # rebuild ran over a node set without it, the shape hash has not moved
    # since, and nothing asks again. Read before the upsert, so a row it
    # inserts is not already among the rows that were there.
    Repo.transaction(fn ->
      existing = existing_rows(target, covered, working_copy_id)
      before = existing |> Enum.map(& &1.id) |> MapSet.new()
      before_ids_by_key = Map.new(existing, &{{&1.entity_type, &1.owner_id, &1.name}, &1.id})

      written =
        nodes
        |> Enum.group_by(& &1.entity_type)
        |> Enum.flat_map(fn {entity_type, group} ->
          upsert_group(target, entity_type, group, working_copy_id, now)
        end)
        |> MapSet.new()

      # `written` only names rows the upsert actually touched -- a row
      # `on_conflict/1`'s guard skipped is covered just the same, so it comes
      # from the input rather than from RETURNING.
      covered_ids =
        for node <- nodes,
            id = Map.get(before_ids_by_key, {node.entity_type, node.entity_id, node.name}),
            not is_nil(id),
            do: id

      kept = MapSet.union(written, MapSet.new(covered_ids))

      departed = MapSet.difference(before, kept)
      delete_ids(MapSet.to_list(departed), target)

      %{inserted: MapSet.size(MapSet.difference(kept, before)), reaped: MapSet.size(departed)}
    end)
  end

  # One upsert per entity type, because each has its own conflict target.
  # Answers the `{owner_id, name}` pairs it wrote, which is what the reap needs
  # to know to leave them alone.
  # Returns the ids the write landed on, so the departed rows can be subtracted
  # rather than reconstructed.
  defp upsert_group(target, entity_type, nodes, working_copy_id, now) do
    rows = Enum.map(nodes, &row(&1, entity_type, &1.entity_id, working_copy_id, now))

    rows
    |> Enum.chunk_every(div(@bind_budget, map_size(hd(rows))))
    |> Enum.flat_map(fn chunk ->
      {_n, returned} =
        Repo.insert_all(target, chunk,
          on_conflict: on_conflict(target),
          conflict_target: conflict_target(entity_type),
          returning: [:id]
        )

      Enum.map(returned, & &1.id)
    end)
  end

  # Everything the covered entities own that this write did not produce.
  #
  # One statement per entity rather than one for all of them, for the reason
  # `owner_filter/2` is shaped the way it is: the three owner columns are
  # different columns, and a covered set mixes types freely.
  # Rows the write did not land on, for the entities it covered.
  #
  # One select and one delete per owner kind, not one delete per entity. This
  # was `Enum.each(covered, ... Repo.delete_all())` — a `DELETE` per covered
  # entity, which on a seed is every entity in the project, once per vantage.
  # Nine vantages of ~1,300 entities is where most of the seed's 26,395 queries
  # came from.
  #
  # The same shape `NodeRepository.delete_departed/4` uses on the pass side:
  # select the candidates for the covered owners, subtract in memory what the
  # write just returned, delete what is left. `kept` is a set of ids, which is
  # exact — a row this write produced is kept whatever it is named.
  # What an upsert overwrites on conflict, and when `checked_at` moves.
  #
  # `checked_at` is what `computed_at` on every graph read is made of, and it
  # has to mean one thing whichever path wrote the row. A sweep stamps a row
  # only when its answer moved — both halves of `sweep/2` carry
  # `IS DISTINCT FROM` — so a whole-vantage write stamps the same way, or the
  # one un-narrowed writer left in the system restamps every row it touches
  # and a read sees every verdict "reconsidered" by an analyzer run that
  # changed nothing (criterion 3448). Every row is still updated, so
  # `returning: [:id]` still names them all and the reap leaves them alone.
  #
  # Named columns rather than `:replace_all`, which would overwrite `id` and
  # `inserted_at` — and the id is the whole point of upserting here.
  defp on_conflict({_table, _schema} = target) do
    from(n in target,
      update: [
        set: [
          satisfied: fragment("EXCLUDED.satisfied"),
          details: fragment("EXCLUDED.details"),
          description: fragment("EXCLUDED.description"),
          inputs_fingerprint: fragment("EXCLUDED.inputs_fingerprint"),
          owner_component_type: fragment("EXCLUDED.owner_component_type"),
          node_scope: fragment("EXCLUDED.node_scope"),
          updated_at: fragment("EXCLUDED.updated_at"),
          checked_at:
            fragment(
              "CASE WHEN ? IS DISTINCT FROM EXCLUDED.satisfied OR ? IS DISTINCT FROM EXCLUDED.details THEN EXCLUDED.checked_at ELSE ? END",
              n.satisfied,
              n.details,
              n.checked_at
            )
        ]
      ],
      # 181f3469: a row EXCLUDED agrees with on every stored column is left
      # alone rather than rewritten -- no new tuple, no WAL, no index churn,
      # on a drain that is otherwise thousands of writes changing nothing.
      # Postgres answers RETURNING only for rows this touches, so a skipped
      # row is invisible to it -- `write/3` gets `kept` from the rows it was
      # asked to write, not from this result, so a merely-unchanged row does
      # not read as reaped.
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

  # Every row the covered owners hold at this vantage, with the natural key
  # (owner, name) that identifies it. What a write may reap is exactly this
  # set minus what it still covers — and never a row of an owner it did not
  # cover. Carries the key, not just the id, because `on_conflict/1` skips
  # RETURNING a row it leaves unchanged, so `write/3` has to know what this
  # write still covers from its own input rather than from that result.
  defp existing_rows(target, covered, working_copy_id) do
    story_ids = for {"story", id} <- covered, do: id

    issue_ids =
      target
      |> where([n], not is_nil(n.issue_id))
      |> where(
        [n],
        n.issue_id in subquery(
          from(i in CodeMySpec.Issues.Issue, where: i.story_id in ^story_ids, select: i.id)
        ) or fragment("(?->>'story_id')::bigint", n.details) in ^story_ids
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

  defp select_existing(query, "component" = entity_type),
    do:
      select(query, [n], %{
        id: n.id,
        name: n.name,
        owner_id: n.component_id,
        entity_type: ^entity_type
      })

  defp select_existing(query, "story" = entity_type),
    do:
      select(query, [n], %{
        id: n.id,
        name: n.name,
        owner_id: n.story_id,
        entity_type: ^entity_type
      })

  defp select_existing(query, "issue" = entity_type),
    do:
      select(query, [n], %{
        id: n.id,
        name: n.name,
        owner_id: n.issue_id,
        entity_type: ^entity_type
      })

  defp select_existing(query, "project" = entity_type),
    do:
      select(query, [n], %{
        id: n.id,
        name: n.name,
        owner_id: n.project_id,
        entity_type: ^entity_type
      })

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

  # The three partial unique indexes, matching `NodeRepository.owner/1`. An
  # `unsafe_fragment` because the index is partial and Ecto cannot name one any
  # other way; the predicates are literals here, not interpolation.
  defp conflict_target("component"),
    do: {:unsafe_fragment, "(component_id, name, working_copy_id) WHERE component_id IS NOT NULL"}

  defp conflict_target("issue"),
    do: {:unsafe_fragment, "(issue_id, name, working_copy_id) WHERE issue_id IS NOT NULL"}

  defp conflict_target("story"),
    do: {:unsafe_fragment, "(story_id, name, working_copy_id) WHERE story_id IS NOT NULL"}

  defp conflict_target("project"),
    do: {:unsafe_fragment, "(project_id, name, working_copy_id) WHERE project_id IS NOT NULL"}

  @doc """
  Set one requirement's verdict, without recomputing anything around it.

  What an event handler writes. `GraphStore.write/3` replaces everything an entity
  owns and is what a recompute needs; this touches the single row the event
  settled and leaves its siblings alone — which is the whole difference between
  applying an event and re-deriving from one.

  Answers `{:ok, 0}` when no row matched, and that is information rather than a
  failure: the projection only holds rows the seed created, so a miss means the
  event named an entity this vantage has never projected. The caller counts
  those — a handler quietly writing nothing is a silent failure otherwise.
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
          checked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      )

    {:ok, count}
  end

  @doc """
  Settle one requirement across every entity of a type, then the exceptions.

  What a set-based handler writes. `story_issues_triaged` uses a grouped query
  naming stories that carry incoming issues; every other story is triaged
  *by absence*, and there is no list of them to iterate. So the default
  goes on with one `UPDATE`, and the named few are corrected after.

  Two statements for a population of any size, which is the whole reason a
  handler owns a requirement rather than an entity.

  ## Neither statement writes a row whose answer did not move

  Both halves carry `IS DISTINCT FROM`, and it is not only an optimisation.

  A sweep used to rewrite every row of a requirement on every drain, which
  `DrainCost` measured at 1,264 rows for one `files_synced` where a full
  recompute of the same vantage wrote 15 — the same values written over
  themselves, plus the index maintenance behind them.

  It is also what `checked_at` has to mean. `computed_at` on every graph read is
  `max(checked_at)`, and story 1063 asserts it *holds still* when nothing
  changed — `criterion_3231` compares it across a heartbeat that carried no
  change. A sweep that stamps every row moves that timestamp on every drain, so
  without this the event projection fails three criteria the batched pass
  passes, for work it did not do.

  ## The two halves are disjoint, which is why order no longer matters

  The default used to run across the whole population and the exceptions
  corrected it afterwards, so ordering was load-bearing. With `IS DISTINCT FROM`
  that breaks: an exception row already holding its exception value would be
  written to the default and then written back, netting no change and two
  writes. So the default excludes the exception entities outright and each half
  owns its own rows.

  The transaction stays. A reader landing between them still sees the new
  default beside the exceptions' previous values, which is a projection claiming
  every component has a spec.

  ## One statement for the exceptions, and it used to be one per entity

  `Enum.each(spec.except, &put_verdict/2)` was a round trip per entity inside the
  transaction, which made the claim above true for the issue requirements and
  false for every one whose exceptions are per entity. `DrainCost` read it on
  the first try: one `files_synced` cost **6,614 queries** where a full
  recompute of the same vantage cost 57 — 1,140 `UPDATE`s for `review_file`,
  another 1,140 for `review_valid`, 6,536 in total. The event projection was
  correct and more expensive than the pass it replaces.

  So the exceptions go in one statement, joined against an `unnest` of their own
  values. The verdicts genuinely differ per entity — a missing spec carries its
  own `expected_path` — so there is no grouping that collapses them, and the
  array is the shape that does.

  Answers how many rows it actually wrote — not how many it matched, which is
  the whole population and says nothing.
  """
  @spec sweep(Scope.t(), map()) :: {:ok, non_neg_integer()}
  def sweep(%Scope{} = scope, %{entity_type: entity_type, name: name} = spec) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    ids = Enum.map(spec.except, &cast_id(entity_type, &1.entity_id))

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
  # `NOT (owner = ANY($ids))` rather than `NOT IN`, so the exception ids travel
  # as one array parameter instead of one bind per entity — the same reason
  # `put_verdicts/5` uses `unnest`. An empty array excludes nothing, because
  # `x = ANY('{}')` is false.
  #
  # Scoped to the project, which it was not, and `put_verdicts/5` beside it does
  # not have to be: that one names each entity id, and an id belongs to one
  # project. A default names none of them — it is "every row of this requirement
  # the exceptions left over" — so without a project predicate the leftovers are
  # every project's.
  #
  # The vantage column hid it for eight of nine vantages. A `working_copy_id` is
  # a checkout of one project, so `IS NOT DISTINCT FROM $5` scopes the sweep by
  # accident wherever the vantage is a real copy. `nil` is the vantage every
  # project shares — it is what every reader that is not an agent resolves to —
  # and there the predicate stopped scoping anything.
  #
  # Measured on dev, 2026-09-17: the unscoped project row for this project read
  # `qa_journey_wallaby` satisfied, "4 file(s) at test/journeys/", against a tree
  # that has no such directory. The four files are in another project's checkout,
  # and its drain wrote this project's answer.
  defp settle_default(scope, entity_type, name, spec, ids, now) do
    {table, _schema} = event_target()
    owner = owner_column(entity_type)

    # `$2::text::jsonb`, never `$2::jsonb`. Postgres infers a parameter's type
    # from its cast and tells Postgrex, so `::jsonb` makes Postgrex encode the
    # already-encoded binary *again* — the column ends up holding the jsonb
    # string `"{\"status\":…}"` rather than an object, and the next read fails
    # with `cannot load ... as type :map`. Declaring it text hands the bytes over
    # untouched and lets Postgres parse them, which is what `put_verdicts/5`
    # does with its `text[]`.
    sql = """
    UPDATE #{table} AS n
       SET satisfied = $1,
           details = $2::text::jsonb,
           checked_at = $3,
           updated_at = $3
     WHERE n.name = $4
       AND n.working_copy_id IS NOT DISTINCT FROM $5
       AND n.#{owner} IS NOT NULL
       AND #{project_predicate(entity_type)}
       AND NOT (n.#{owner} = ANY($6::#{id_type(entity_type)}[]))
       AND (n.satisfied IS DISTINCT FROM $1 OR n.details IS DISTINCT FROM $2::text::jsonb)
    """

    %{num_rows: rows} =
      Repo.query!(sql, [
        spec.default,
        Jason.encode!(spec.default_details),
        now,
        name,
        cast_vantage(Projection.vantage(scope)),
        ids,
        Ecto.UUID.dump!(scope.active_project_id)
      ])

    {:ok, rows}
  end

  # Which of these rows are this project's.
  #
  # Three shapes because the column that answers it differs. A project row
  # carries `project_id` and says so directly; a component or story row carries
  # only its owner's id — `project_id` is null on all 14,975 of them — so the
  # owner table is what knows. `EXISTS` against a primary key, once per swept
  # requirement.
  defp project_predicate("project"), do: "n.project_id = $7"

  defp project_predicate("component"),
    do: "EXISTS (SELECT 1 FROM components c WHERE c.id = n.component_id AND c.project_id = $7)"

  defp project_predicate("issue"),
    do: "EXISTS (SELECT 1 FROM issues i WHERE i.id = n.issue_id AND i.project_id = $7)"

  defp project_predicate("story"),
    do: "EXISTS (SELECT 1 FROM stories s WHERE s.id = n.story_id AND s.project_id = $7)"

  @doc """
  Correct many entities' verdicts for one requirement, in one statement.

  The batch form of `put_verdict/2`. Same rows, same values; what changes is
  that the entity ids, verdicts and details travel as three arrays and Postgres
  joins them against the table itself, instead of the client issuing one
  `UPDATE` per entity.

  Answers how many rows matched, which is not the same as how many were asked
  for: settling writes rows and never creates them, so an entity this vantage
  has never projected is a miss, and a miss is information the caller counts.
  """
  @spec put_verdicts(Scope.t(), String.t(), String.t(), [map()], NaiveDateTime.t()) ::
          {:ok, non_neg_integer()}
  def put_verdicts(scope, entity_type, name, changes, now \\ nil)

  def put_verdicts(%Scope{}, _entity_type, _name, [], _now), do: {:ok, 0}

  def put_verdicts(%Scope{} = scope, entity_type, name, changes, now) do
    now = now || NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    {table, _schema} = event_target()

    # `IS NOT DISTINCT FROM` rather than `=`, because the vantage is nullable and
    # the null means something: the unscoped row is the project-wide answer, and
    # the unique indexes use `NULLS NOT DISTINCT` to keep exactly one of it.
    # `=` against null matches nothing, which would silently settle none of them.
    sql = """
    UPDATE #{table} AS n
       SET satisfied = v.satisfied,
           details = v.details::jsonb,
           checked_at = $1,
           updated_at = $1
      FROM unnest($2::#{id_type(entity_type)}[], $3::boolean[], $4::text[])
        AS v(entity_id, satisfied, details)
     WHERE n.#{owner_column(entity_type)} = v.entity_id
       AND n.name = $5
       AND n.working_copy_id IS NOT DISTINCT FROM $6
       AND (n.satisfied IS DISTINCT FROM v.satisfied
         OR n.details IS DISTINCT FROM v.details::jsonb)
    """

    %{num_rows: rows} =
      Repo.query!(sql, [
        now,
        Enum.map(changes, &cast_id(entity_type, &1.entity_id)),
        Enum.map(changes, & &1.satisfied),
        Enum.map(changes, &Jason.encode!(&1.details)),
        name,
        cast_vantage(Projection.vantage(scope))
      ])

    {:ok, rows}
  end

  defp owner_column("component"), do: "component_id"
  defp owner_column("issue"), do: "issue_id"
  defp owner_column("story"), do: "story_id"
  defp owner_column("project"), do: "project_id"

  defp id_type("story"), do: "bigint"
  defp id_type(_uuid_owner), do: "uuid"

  defp cast_id("story", id), do: id
  defp cast_id(_uuid_owner, id), do: Ecto.UUID.dump!(id)

  defp cast_vantage(nil), do: nil
  defp cast_vantage(vantage), do: Ecto.UUID.dump!(vantage)

  @doc """
  Replace this vantage's whole topology.

  A full replace rather than a delta, because a transitive reduction is global:
  adding one node can remove an edge between two others, so there is no subset
  of edges a change is confined to. `RequirementGraph.compute_topology/3` says
  the same thing from the other side.

  That is affordable because it is rare. Edges are a function of the node set
  and a sweep cannot change the node set — only a drain that wrote or reaped
  nodes has to call this, which is the same small set of events that already
  falls back to a recompute.

  Stored as the pair of node keys the edge actually is, not as row ids, so a
  diff compares what the edge means rather than which rows happen to carry it.
  """
  @spec write_edges(Scope.t(), [%{from: tuple(), to: tuple()}], map() | nil) ::
          {:ok, non_neg_integer()}
  def write_edges(%Scope{active_project_id: project_id} = scope, edges, ids \\ nil) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # An edge references rows in its own node table, and the two projections
    # number their rows differently, so the ids are only meaningful beside the
    # nodes this same drain just wrote — which is why they are resolved here
    # rather than carried in by the caller, unless the caller holds the map
    # this drain already resolved (`node_ids/1`) for the same vantage.
    ids = ids || ids_by_owner_key(project_id, working_copy_id)

    # An endpoint with no row is not an edge.
    #
    # These used to be written with a null id beside the entity key, which is
    # how a table full of edges pointing at nothing looked like a table full of
    # edges. `edge_keys/6` has always dropped them on the read side; dropping
    # them on the write side is the same rule applied where it can be enforced,
    # and the column is `null: false` now.
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

    # The difference, not the whole set.
    #
    # This deleted every edge at this vantage and inserted them all back, on any
    # observation that moved topology at all. Measured on this project: 124,760
    # edges, so ~249,500 row writes to express one component appearing — and
    # components move about fifty times an hour while agents work, which made
    # this 79% of all write volume.
    #
    # `NodeRepository.replace_edges/3` has always done it properly for the real
    # table: delete only what is no longer wanted, insert with
    # `on_conflict: :nothing` so an unchanged edge costs nothing. After the swap
    # the event path inherits this writer, so the naive version would not have
    # fixed itself by flipping the flag.
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

  # What this vantage already holds, by identity. Compared in memory rather than
  # as a `NOT IN`, because the set runs to tens of thousands and the bind limit
  # that broke the insert would break that the same way.
  #
  # Scoped through the vantage's node ids rather than through a `working_copy_id`
  # column, which this table no longer has and the real one never did. The ids
  # are the ones `write_edges/2` has already resolved, so the narrowing costs
  # nothing: no join, no second query. Checking the `from` end is enough —
  # `compute_topology/3` builds edges within one vantage, and a node id belongs
  # to exactly one.
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

  # What makes two edges the same edge: the rows it joins.
  #
  # This was the entity/name pair on both ends, and the ids were not in it. An
  # edge whose endpoints had been deleted and reinserted — which `write/3` did
  # to every covered row until it learned to upsert — matched by identity, was
  # neither deleted nor reinserted, and kept pointing at rows that no longer
  # existed. `edge_keys/6` resolves an edge through its own nodes, so it dropped
  # out of every comparison: in the table and gone from the graph, permanently,
  # because the only writer that could have fixed it believed it was correct.
  #
  # Measured 2026-09-17, once `log/1` started printing the numbers: every
  # project reported its whole topology missing — 27,045 edges live and zero
  # resolvable at this project's unscoped vantage alone.
  #
  # The keys are gone now and the ids are the whole identity, which is the same
  # thing `requirement_edges` has always meant by an edge.
  defp edge_identity(row), do: {row.from_requirement_id, row.to_requirement_id}

  @doc """
  Whether this vantage has been projected at all.

  Asked of the project's own rows, because every seed writes them and nothing
  narrower does. A vantage with none has nothing to be partial against — the
  pass's `no_stored_rows` — and it is the one question a settle has to ask
  before it trusts the marks: a checkout somebody just read, with no mark
  naming it, is otherwise never written. One indexed query.
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

  A projector meeting a vantage with rows trusts them. That is right for what
  observations move and wrong for what a release moves: `questions_answered`
  shipped in v2.0.147 and on dev the next morning not one of the big
  project's 138 stories had the row at any of its eleven vantages, because a
  handler settles rows and never creates them, and nothing seeds a vantage
  that has rows. So arrival compares names as well as presence, per entity
  type, and a vantage whose rows predate a definition is seeded like one that
  has none. One query per vantage per process.

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

  # The project's entities, for scoping both sides of a comparison the way
  # `Projection.project_rows/3` scopes its own read. Ids rather than a context
  # because neither caller has one.
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

  # Every row owned by an entity of this type, whichever entity. The sweep's
  # first half — "this requirement is satisfied unless something said otherwise".
  defp owner_filter("component", id), do: dynamic([n], n.component_id == ^id)
  defp owner_filter("issue", id), do: dynamic([n], n.issue_id == ^id)
  defp owner_filter("story", id), do: dynamic([n], n.story_id == ^id)
  defp owner_filter("project", id), do: dynamic([n], n.project_id == ^id)

  # `is_nil` rather than `== nil`, for the reason `Projection.copy_filter/1`
  # gives: `= NULL` is never true, so the unscoped vantage would match no row
  # and every comparison would report the whole projection missing.
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

  # Postgres binds one parameter per column per row and counts them in a 16-bit
  # field — 65,535 for the whole statement, whatever its size — so the write has
  # to be chunked exactly as `NodeRepository.insert_every/3` chunks the node
  # insert.
  #
  # Measured from the row rather than written down. This was `div(60_000, 9)`
  # until the rows learned their row ids and became eleven columns wide, and
  # nothing recomputed the constant: 6,666 rows times eleven is 73,326, which is
  # exactly what Postgres refused. Every edge write raised, the marks were left
  # pending, and the projector retried the same failing write every three
  # seconds. A budget that has to be edited in step with a map literal three
  # hundred lines away is a budget that will be wrong again.
  defp insert_edges([]), do: 0

  # `on_conflict: :nothing` on the pair of ends, which this table has a unique
  # index for now and did not before — the reason the difference above had to
  # decide what was new rather than letting the database tell it. It still does,
  # because it also has to know what is *stale*; this is what makes a concurrent
  # drain harmless rather than a duplicate. Same options
  # `NodeRepository.replace_edges/3` passes for the real table, which is the
  # writer this one becomes at the swap.
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

  # Every node this projection holds at this vantage, by the same key the edges
  # name their ends with. `owner_key/4` already renders every owner as
  # `{type, id-as-text, name}`, which is exactly the shape an edge end carries.
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

  # `entity_id` as text on both sides: a component's is a uuid and a story's is
  # a bigint, and the rows store the pair rather than pointing at a row.
  defp owner_key(component_id, _story, _project, _issue, name) when not is_nil(component_id),
    do: {"component", component_id, name}

  defp owner_key(_component, story_id, _project, _issue, name) when not is_nil(story_id),
    do: {"story", to_string(story_id), name}

  defp owner_key(_component, _story, _project, issue_id, name) when not is_nil(issue_id),
    do: {"issue", issue_id, name}

  defp owner_key(_component, _story, project_id, _issue, name),
    do: {"project", project_id, name}
end
