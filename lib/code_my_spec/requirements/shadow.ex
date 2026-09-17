defmodule CodeMySpec.Requirements.Shadow do
  @moduledoc """
  The event-derived projection, and how far it is from the real one.

  `shadow_requirements` mirrors `requirements` column for column, so the same
  nodes land the same way and a difference between the two tables is a
  difference in the *decision* that produced them — which is the only variable
  under test. Everything downstream of that decision is shared.

  ## What the diff means, and which direction is fatal

  Three numbers, and they are not equally bad:

    * `missing` — the live projection has a row the shadow does not. The event
      path never computed that entity, so a writer owes a mark. This is the
      direction that must reach zero: in production it is a requirement nobody
      revisits, which costs an agent a session.

    * `extra` — the shadow has a row the live projection does not. Usually the
      shadow computed an entity the live pass had no reason to, which costs a
      recompute and nothing else.

    * `disagree` — both have the row and the verdicts differ. The expensive one
      to read, because it is either a stale shadow row (a missed mark, same as
      `missing`) or a genuine computation difference, and the sample is what
      tells them apart.

  A run of passes at `missing: 0, disagree: 0` is what earns the swap.

  ## What the diff cannot see

  It proves *coverage*, not *narrowness*. A writer that names nothing records a
  project-wide mark, the projector reads that as "any of it" and recomputes
  every entity, and the diff agrees — exactly as it would for a writer that
  named its entities precisely. Verified by turning `Invalidations` off
  entirely, which is the only thing that makes the comparison fail: a story
  created after the seed came back as three `missing` rows, named.

  So this number answers "would the event path have missed something", and the
  cost question — how often a project-wide mark drags the whole project through
  a recompute that a narrowed writer would have avoided — is a different
  measurement, taken from how often those marks fire. Reading agreement as
  evidence of narrowness is the mistake this paragraph exists to prevent.

  ## Why the diff is not per event

  Writing is per entity and per event — that is the point. Comparing is not:
  it reads both projections whole, so doing it per event would cost more than
  the thing it measures. It runs on the fingerprint pass, which is already
  loading the context and is exactly the moment the two systems can be asked
  the same question.
  """

  import Ecto.Query, only: [from: 2, where: 2, where: 3, dynamic: 2, select: 3]

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  # Postgres binds one parameter per column per row and counts them in a 16-bit
  # field. Declared here rather than beside its first user, because a module
  # attribute is read at the point of use during compilation: defined lower down,
  # it was `nil` in `delete_edges_outside/3` and `chunk_every/2` raised.
  @bind_budget 60_000

  @shadow_table {"shadow_requirements", Node}
  @real_table {"requirements", Node}
  @shadow_edges "shadow_requirement_edges"
  @real_edges "requirement_edges"

  @doc """
  Whether the event path has taken over the tables readers actually read.

  The two projections are the same shape in two tables, and which one is
  authoritative is the whole question this module exists to answer. While it is
  being answered, the pass writes `requirements` — what every reader loads — and
  the event path writes `shadow_requirements`, where being wrong costs nothing.

  Flipping this swaps them. The event path takes `requirements`, the pass is
  demoted to `shadow_requirements`, and `diff/1` goes on comparing the same two
  things in the same direction, because it asks for its two sides by role rather
  than by name.

  Runtime rather than a deploy, for the reason the projection was built behind a
  flag at all: this is the change that cannot be half-made. If the event path is
  wrong about one requirement, every reader is wrong about it, and the way back
  has to be a config change rather than a release.

  ## Not yet safe to turn on

  This moves the node tables and nothing else, and the halves are not
  symmetrical. `requirements` and `shadow_requirements` carry the same three
  owner+name unique indexes, so either writer can own either table. The edge
  tables do not match: `requirement_edges` joins two row ids, while
  `shadow_requirement_edges` stores the entity/name key on both ends, because
  the event path writes edges before it knows what row ids the nodes got.

  So flipping this today would hand the event path `requirements` while leaving
  `requirement_edges` to a pass that no longer writes the rows those ids point
  at. The way through is the machinery already here — `NodeRepository`'s
  `ids_by_key/3` resolves exactly that mapping and `replace_edges/3` already
  takes it — so the event path resolves its keys after writing nodes and writes
  real edges, rather than a second edge table existing at all. Until that lands,
  leave this alone.
  """
  @spec inverted?() :: boolean()
  def inverted?, do: Application.get_env(:code_my_spec, :graph_event_is_source, false)

  @doc """
  Where the event path writes, and where the pass does.

  Asked by role, so no call site has to know which way round the flag currently
  is — which is the point: the ones in `NodeRepository` belong to the pass and
  the ones here belong to the event path, and neither should change when they
  trade tables.
  """
  @spec event_target() :: {String.t(), module()}
  def event_target, do: if(inverted?(), do: @real_table, else: @shadow_table)

  @spec pass_target() :: {String.t(), module()}
  def pass_target, do: if(inverted?(), do: @shadow_table, else: @real_table)

  @spec event_edges() :: String.t()
  def event_edges, do: if(inverted?(), do: @real_edges, else: @shadow_edges)

  @spec pass_edges() :: String.t()
  def pass_edges, do: if(inverted?(), do: @shadow_edges, else: @real_edges)

  @type entity :: {String.t(), term()}

  @type report :: %{
          missing: non_neg_integer(),
          extra: non_neg_integer(),
          disagree: non_neg_integer(),
          live: non_neg_integer(),
          shadow: non_neg_integer(),
          edges_missing: non_neg_integer(),
          edges_extra: non_neg_integer(),
          live_edges: non_neg_integer(),
          shadow_edges: non_neg_integer(),
          sample: [String.t()]
        }

  @doc """
  Whether the shadow projection is being maintained.

  Separate from `Invalidations.enabled?/0`: recording marks is cheap and useful
  on its own, where maintaining a second projection is the expensive half. Off
  turns the experiment off without losing the marks that would let it restart.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:code_my_spec, :graph_shadow_projection, false)

  @doc """
  Replace the shadow rows for everything this computation covered.

  Delete-then-insert rather than the live path's upsert-then-reap. The live
  writer has to handle a whole graph at once and reap what it did not produce;
  this holds a known, small set of entities, so "these are their rows" is the
  whole statement and the narrower operation is the honest one.

  `covered` and the nodes' own owners are deliberately separate inputs.
  `RequirementGraph.compute_entity/4` answers for a component's whole family —
  a context's template produces its children's rows, so they cannot be computed
  apart from it — and within that family a member can legitimately produce
  nothing. Deleting by `covered` and inserting by each node's own owner is what
  makes "this component now has no requirements" expressible; keying both sides
  off the nodes would leave that component's old rows standing forever.
  """
  @spec write(Scope.t(), Enumerable.t(), [map()]) :: :ok
  def write(%Scope{} = scope, covered, nodes) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(nodes, &row(&1, &1.entity_type, &1.entity_id, working_copy_id, now))

    Repo.transaction(fn ->
      Enum.each(covered, fn {entity_type, entity_id} ->
        event_target()
        |> where(^owner_filter(entity_type, entity_id))
        |> where(^copy_filter(working_copy_id))
        |> Repo.delete_all()
      end)

      case rows do
        [] -> :ok
        rows -> Repo.insert_all(event_target(), rows)
      end
    end)

    :ok
  end

  @doc """
  Set one requirement's verdict, without recomputing anything around it.

  What an event handler writes. `Shadow.write/3` replaces everything an entity
  owns and is what a recompute needs; this touches the single row the event
  settled and leaves its siblings alone — which is the whole difference between
  applying an event and re-deriving from one.

  Answers `{:ok, 0}` when no row matched, and that is information rather than a
  failure: the projection only holds rows the seed created, so a miss means the
  event named an entity this vantage has never projected. The caller counts
  those — a handler quietly writing nothing is exactly the silent failure the
  shadow exists to catch.
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

  What a set-based handler writes. `story_issues_resolved` is one grouped query
  naming the few stories that carry an unresolved issue; every other story is
  resolved *by absence*, and there is no list of them to iterate. So the default
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
        ids
      ])

    {:ok, rows}
  end

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

  Stored as the pair of node keys the edge actually is, not as row ids. The
  shadow's ids come from their own sequence, so an id-keyed edge would point at
  a different requirement in each table — not missing, *wrong*, and a diff
  comparing ids would be comparing noise.
  """
  @spec write_edges(Scope.t(), [%{from: tuple(), to: tuple()}]) :: {:ok, non_neg_integer()}
  def write_edges(%Scope{active_project_id: project_id} = scope, edges) do
    working_copy_id = Projection.vantage(scope)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Row ids as well as keys, so this table can eventually be the shape the real
    # one is. An edge references rows in its own node table, and the two
    # projections number their rows differently, so the ids are only meaningful
    # beside the nodes this same sweep just wrote — which is why they are
    # resolved here rather than carried in by the caller.
    ids = ids_by_owner_key(project_id, working_copy_id)

    rows =
      edges
      |> Enum.uniq()
      |> Enum.map(fn %{from: {ft, fi, fname}, to: {tt, ti, tname}} ->
        %{
          project_id: Ecto.UUID.dump!(project_id),
          working_copy_id: working_copy_id && Ecto.UUID.dump!(working_copy_id),
          from_entity_type: ft,
          from_entity_id: to_string(fi),
          from_name: fname,
          from_requirement_id: Map.get(ids, {ft, to_string(fi), fname}),
          to_entity_type: tt,
          to_entity_id: to_string(ti),
          to_name: tname,
          to_requirement_id: Map.get(ids, {tt, to_string(ti), tname}),
          inserted_at: now
        }
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
        held = held_edges(project_id, working_copy_id)
        wanted = MapSet.new(rows, &edge_identity/1)

        stale = for {identity, id} <- held, not MapSet.member?(wanted, identity), do: id
        fresh = Enum.reject(rows, &Map.has_key?(held, edge_identity(&1)))

        delete_edges(stale) + insert_edges(fresh)
      end)

    {:ok, count}
  end

  # What this vantage already holds, by identity. Compared in memory rather than
  # as a `NOT IN`, because the set runs to tens of thousands and the bind limit
  # that broke the insert would break that the same way.
  #
  # Identity rather than `on_conflict: :nothing`: this table carries no unique
  # index on the pair of ends, so the database cannot tell a duplicate from a
  # new row and every reprojection would append the whole set again.
  defp held_edges(project_id, working_copy_id) do
    event_edges()
    |> where([e], e.project_id == type(^project_id, Ecto.UUID))
    |> where(^edge_copy_filter(working_copy_id))
    |> select(
      [e],
      {e.id, e.from_entity_type, e.from_entity_id, e.from_name, e.to_entity_type, e.to_entity_id,
       e.to_name}
    )
    |> Repo.all()
    |> Map.new(fn {id, ft, fi, fname, tt, ti, tname} ->
      {{ft, fi, fname, tt, ti, tname}, id}
    end)
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

  # What makes two edges the same edge, independent of which row is holding it.
  defp edge_identity(row) do
    {row.from_entity_type, row.from_entity_id, row.from_name, row.to_entity_type,
     row.to_entity_id, row.to_name}
  end

  @doc """
  How far the shadow is from the live projection, for this reader's vantage.

  Scoped through the *context*, not through the project's tables, and the
  distinction is the whole difference between a meaningful number and a
  meaningless one. `Preloader.load/1` narrows stories per working copy —
  assigned here or unassigned — so a vantage's context holds fewer stories than
  the project has, and `Projection.load/2` reads rows for exactly that set.

  The live table holds more than that. `delete_departed/4` reaps only among the
  entities a pass visited, so a partial recompute leaves rows standing for
  entities that vantage's context no longer includes; `departed/2` filters them
  out of the served graph rather than deleting them. Measured on dev: one
  vantage's context had 38 stories where the table held rows for 121, and
  comparing against the table reported 522 rows `missing` that the live
  projection would never have served.

  So this loads a context and asks both sides the same question. That costs a
  preload, which is the right price for a diagnostic that is otherwise reporting
  on the wrong population.
  """
  @spec diff(Scope.t()) :: report()
  def diff(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    working_copy_id = Projection.vantage(scope)
    {:ok, ctx} = Preloader.load(scope)
    component_ids = Enum.map(ctx.components, & &1.id)
    story_ids = Enum.map(ctx.stories, & &1.id)

    live = verdicts(pass_target(), project_id, component_ids, story_ids, working_copy_id)
    shadow = verdicts(event_target(), project_id, component_ids, story_ids, working_copy_id)

    live_keys = MapSet.new(Map.keys(live))
    shadow_keys = MapSet.new(Map.keys(shadow))

    missing = MapSet.difference(live_keys, shadow_keys)
    extra = MapSet.difference(shadow_keys, live_keys)

    disagree =
      live_keys
      |> MapSet.intersection(shadow_keys)
      |> Enum.filter(&(Map.fetch!(live, &1) != Map.fetch!(shadow, &1)))

    live_edges =
      edge_keys(pass_target(), pass_edges(), project_id, component_ids, story_ids, working_copy_id)

    shadow_edges =
      edge_keys(event_target(), event_edges(), project_id, component_ids, story_ids, working_copy_id)

    %{
      missing: MapSet.size(missing),
      extra: MapSet.size(extra),
      disagree: length(disagree),
      live: map_size(live),
      shadow: map_size(shadow),
      edges_missing: MapSet.size(MapSet.difference(live_edges, shadow_edges)),
      edges_extra: MapSet.size(MapSet.difference(shadow_edges, live_edges)),
      live_edges: MapSet.size(live_edges),
      shadow_edges: MapSet.size(shadow_edges),
      sample: sample(missing, extra, disagree)
    }
  end

  def diff(%Scope{}), do: empty_report()

  @doc """
  Say where the shadow stands, on the pass that measured it.

  One line, in the shape the other `[Requirements]` lines take, because this
  number is read against them — a diff is only meaningful beside the pass that
  produced it.
  """
  @spec log(report()) :: :ok
  def log(%{live: 0, shadow: 0}), do: :ok

  def log(report) do
    verdict = if report.missing == 0 and report.disagree == 0, do: "agrees", else: "differs"

    Logger.info(
      "[Requirements] shadow #{verdict} — missing #{report.missing}, " <>
        "extra #{report.extra}, disagree #{report.disagree} " <>
        "(live #{report.live}, shadow #{report.shadow})" <> sample_suffix(report.sample)
    )
  end

  @doc "Forget the shadow projection for this vantage, so it rebuilds from scratch."
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

  # `{owner, name} => satisfied`, which is the whole of what a projection
  # claims. Everything else on a row is rehydrated from the registry at read
  # time — `Node`'s own moduledoc says a row is "identity plus verdict" — so
  # comparing more would be comparing the registry against itself.
  defp verdicts(source, project_id, component_ids, story_ids, working_copy_id) do
    source
    |> scoped(project_id, component_ids, story_ids)
    |> where(^copy_filter(working_copy_id))
    |> select_verdicts()
    |> Repo.all()
    |> Map.new(fn {component_id, story_id, proj_id, name, satisfied} ->
      {{component_id, story_id, proj_id, name}, satisfied}
    end)
  end

  defp select_verdicts(query) do
    from(n in query, select: {n.component_id, n.story_id, n.project_id, n.name, n.satisfied})
  end

  defp scoped(source, project_id, component_ids, story_ids) do
    from(n in source,
      where:
        n.component_id in ^component_ids or n.story_id in ^story_ids or
          n.project_id == ^project_id
    )
  end

  # Every row owned by an entity of this type, whichever entity. The sweep's
  # first half — "this requirement is satisfied unless something said otherwise".
  defp owner_filter("component", id), do: dynamic([n], n.component_id == ^id)
  defp owner_filter("story", id), do: dynamic([n], n.story_id == ^id)
  defp owner_filter("project", id), do: dynamic([n], n.project_id == ^id)

  # `is_nil` rather than `== nil`, for the reason `Projection.copy_filter/1`
  # gives: `= NULL` is never true, so the unscoped vantage would match no row
  # and every comparison would report the whole projection missing.
  defp copy_filter(nil), do: dynamic([n], is_nil(n.working_copy_id))
  defp copy_filter(id), do: dynamic([n], n.working_copy_id == ^id)

  # The same rule for the edge table, which has no `Node` schema behind it — a
  # bare source, so the id has to be dumped rather than cast by Ecto.
  defp edge_copy_filter(nil), do: dynamic([e], is_nil(e.working_copy_id))

  defp edge_copy_filter(id),
    do: dynamic([e], e.working_copy_id == type(^id, Ecto.UUID))

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
  defp owner_field("story"), do: :story_id
  defp owner_field("project"), do: :project_id

  defp scope_string(nil), do: nil
  defp scope_string(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_string(scope) when is_binary(scope), do: scope

  # A handful, named, because the counts say how wrong and never say where —
  # which is the gap `why_all/5` had to be added to close on the fingerprint
  # side. Three of each is enough to point at the writer that owes a mark.
  defp sample(missing, extra, disagree) do
    Enum.concat([
      missing |> Enum.take(3) |> Enum.map(&"missing #{key_label(&1)}"),
      extra |> Enum.take(3) |> Enum.map(&"extra #{key_label(&1)}"),
      disagree |> Enum.take(3) |> Enum.map(&"disagree #{key_label(&1)}")
    ])
  end

  defp key_label({component_id, story_id, project_id, name}) do
    owner =
      cond do
        component_id -> "component:#{String.slice(component_id, 0, 8)}"
        story_id -> "story:#{story_id}"
        project_id -> "project"
        true -> "?"
      end

    "#{owner}/#{name}"
  end

  defp sample_suffix([]), do: ""
  defp sample_suffix(sample), do: "; " <> Enum.join(sample, ", ")

  defp empty_report,
    do: %{
      missing: 0,
      extra: 0,
      disagree: 0,
      live: 0,
      shadow: 0,
      edges_missing: 0,
      edges_extra: 0,
      live_edges: 0,
      shadow_edges: 0,
      sample: []
    }

  # The live topology, as node-key pairs.
  #
  # Resolved through the rows rather than compared as ids, because the two
  # tables' ids are independent sequences — see `write_edges/2`. Only edges with
  # both endpoints inside this vantage's population count, which is the same
  # filter `compute_edges/3` applies when it builds them.
  # One projection's edges, as key pairs, whichever tables that projection owns.
  #
  # Both sides go through this, which is the point: an edge references rows in
  # its own node table and the two projections number their rows differently, so
  # comparing ids across them is meaningless. Translating each side back to
  # `{entity_type, id, name}` against its *own* nodes is the only comparison
  # that means anything — and it is what this function did for the live side
  # before either side could move.
  #
  # Scoped by node id rather than by a project column, because only one of the
  # two edge tables has one. Doing it this way lets the same query serve both.
  defp edge_keys(nodes_src, edges_src, project_id, component_ids, story_ids, working_copy_id) do
    rows =
      nodes_src
      |> scoped(project_id, component_ids, story_ids)
      |> where(^copy_filter(working_copy_id))
      |> select([n], {n.id, n.component_id, n.story_id, n.project_id, n.name})
      |> Repo.all()

    key_by_id =
      Map.new(rows, fn {id, component_id, story_id, proj_id, name} ->
        {id, owner_key(component_id, story_id, proj_id, name)}
      end)

    ids = Map.keys(key_by_id)

    edges_src
    |> where([e], e.from_requirement_id in ^ids and e.to_requirement_id in ^ids)
    |> select([e], {e.from_requirement_id, e.to_requirement_id})
    |> Repo.all()
    |> Enum.flat_map(fn {from_id, to_id} ->
      case {Map.get(key_by_id, from_id), Map.get(key_by_id, to_id)} do
        {nil, _} -> []
        {_, nil} -> []
        {from, to} -> [{from, to}]
      end
    end)
    |> MapSet.new()
  end

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

  defp insert_edges([row | _] = rows) do
    rows
    |> Enum.chunk_every(div(@bind_budget, map_size(row)))
    |> Enum.reduce(0, fn chunk, total ->
      total + elem(Repo.insert_all(event_edges(), chunk), 0)
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
    |> select([n], {n.id, n.component_id, n.story_id, n.project_id, n.name})
    |> Repo.all()
    |> Map.new(fn {id, component_id, story_id, proj_id, name} ->
      {owner_key(component_id, story_id, proj_id, name), id}
    end)
  end

  # `entity_id` as text on both sides: a component's is a uuid and a story's is
  # a bigint, and the shadow stores the pair rather than pointing at a row.
  defp owner_key(component_id, _story, _project, name) when not is_nil(component_id),
    do: {"component", component_id, name}

  defp owner_key(_component, story_id, _project, name) when not is_nil(story_id),
    do: {"story", to_string(story_id), name}

  defp owner_key(_component, _story, project_id, name),
    do: {"project", project_id, name}
end
