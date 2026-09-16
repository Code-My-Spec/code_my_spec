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

  import Ecto.Query, only: [from: 2, where: 2, where: 3, dynamic: 2]

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @source {"shadow_requirements", Node}

  @type entity :: {String.t(), term()}

  @type report :: %{
          missing: non_neg_integer(),
          extra: non_neg_integer(),
          disagree: non_neg_integer(),
          live: non_neg_integer(),
          shadow: non_neg_integer(),
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
        @source
        |> where(^owner_filter(entity_type, entity_id))
        |> where(^copy_filter(working_copy_id))
        |> Repo.delete_all()
      end)

      case rows do
        [] -> :ok
        rows -> Repo.insert_all(@source, rows)
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
      @source
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
  handler owns a requirement rather than an entity. Ordered, and it has to be:
  the default would otherwise overwrite the exceptions it was meant to leave
  alone.

  ## Two, and it used to be one per exception

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
  """
  @spec sweep(Scope.t(), map()) :: {:ok, non_neg_integer()}
  def sweep(%Scope{} = scope, %{entity_type: entity_type, name: name} = spec) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # In one transaction, because the two halves contradict each other by
    # design: the default asserts the requirement for every entity, and the
    # exceptions take it back from the ones it is not true of. A read landing
    # between them sees a projection claiming every component has a spec.
    {:ok, count} =
      Repo.transaction(fn ->
        {count, _} =
          @source
          |> where(^entity_type_filter(entity_type))
          |> where(^copy_filter(Projection.vantage(scope)))
          |> where([n], n.name == ^name)
          |> Repo.update_all(
            set: [
              satisfied: spec.default,
              details: spec.default_details,
              checked_at: now,
              updated_at: now
            ]
          )

        put_verdicts(scope, entity_type, name, spec.except, now)

        count
      end)

    {:ok, count}
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
    {table, _schema} = @source

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

    live = verdicts(Node, project_id, component_ids, story_ids, working_copy_id)
    shadow = verdicts(@source, project_id, component_ids, story_ids, working_copy_id)

    live_keys = MapSet.new(Map.keys(live))
    shadow_keys = MapSet.new(Map.keys(shadow))

    missing = MapSet.difference(live_keys, shadow_keys)
    extra = MapSet.difference(shadow_keys, live_keys)

    disagree =
      live_keys
      |> MapSet.intersection(shadow_keys)
      |> Enum.filter(&(Map.fetch!(live, &1) != Map.fetch!(shadow, &1)))

    %{
      missing: MapSet.size(missing),
      extra: MapSet.size(extra),
      disagree: length(disagree),
      live: map_size(live),
      shadow: map_size(shadow),
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

    @source
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
  defp entity_type_filter("component"), do: dynamic([n], not is_nil(n.component_id))
  defp entity_type_filter("story"), do: dynamic([n], not is_nil(n.story_id))
  defp entity_type_filter("project"), do: dynamic([n], not is_nil(n.project_id))

  defp owner_filter("component", id), do: dynamic([n], n.component_id == ^id)
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
    do: %{missing: 0, extra: 0, disagree: 0, live: 0, shadow: 0, sample: []}
end
