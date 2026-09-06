defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph — nodes AND edges — from Files + Problems.

  The graph is entity-agnostic: edges represent real dependencies regardless of
  whether they cross entity boundaries. There are three kinds of edges:

  1. **Same-entity prerequisites**: spec_file → spec_valid (within a component)
  2. **Project → story**: project.qa_setup → story.component_linked (the
     whole-project gate that opens story-level work)
  2. **Story → component tree**: bdd_specs_exist → component's first req;
     component's terminal req → bdd_specs_passing → qa_complete
  3. **Stories → project**: each story's qa_complete → qa_journey_plan
     (project-level fan-in node — gives the requirements graph a structural
     seam where story state aggregates into project state, which the
     graph projector uses to lay out late_project nodes at the bottom band)
  """

  require Logger

  alias CodeMySpec.Requirements.Difference
  alias CodeMySpec.Requirements.GraphCache
  alias CodeMySpec.Requirements.GraphFingerprint
  alias CodeMySpec.Requirements.NodeRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Users.Scope

  @type node_key :: {String.t(), any(), String.t()}
  @type edge :: %{from: node_key(), to: node_key()}

  @doc """
  Compute all nodes and edges for the project.

  Returns `{nodes, edges}` where edges include cross-entity dependencies.
  """
  @spec compute_graph(Scope.t()) :: {[Requirement.t()], [edge()]} | {:error, :no_working_copy}
  def compute_graph(%Scope{} = scope) do
    {preload_us, loaded} = :timer.tc(fn -> Preloader.load(scope) end)

    with {:ok, ctx} <- loaded do
      config = CodeMySpec.Configurations.get_or_create(scope)
      compute_and_publish(scope, ctx, config, preload_us)
    end
  end

  # Publish the computed graph so readers that cannot compute one still have
  # something to show. Deliberately not a memoization for agents: computation
  # never consults the cache, so there is no key that can be wrong.
  #
  # 15 of the 70 requirement definitions use `check_type: :delegate`, handing
  # satisfaction to an arbitrary module. Every one of their inputs is now in the
  # fingerprint, which is what makes `cached_graph/1` safe for agents too:
  #
  #   * six read tables the preloader did not load — rules, criteria, questions,
  #     personas, issues, and `qa_attempts` behind `qa_complete`
  #   * the rest read components, files and stories, covered from the start
  #
  # A `DelegateFiles` digest used to hash a handful of working-copy files off
  # disk, because `classify/1` claimed none of them and they never became rows.
  # Classify claims them now, so `files_digest` covers them by their content
  # hash and the side channel is gone.
  #
  # The gap was real and this is the second time it has been closed. Story 859's
  # spex caught it the first time, when the cache was wired read-through with a
  # fingerprint that watched none of the above.
  #
  # That spex is gone — no `criterion_7321` and no spex anywhere referencing
  # `cached_graph` or `GraphCache`. This comment named it as "the test to run
  # before trusting any change here" long after it stopped existing, which is
  # worse than naming nothing: it reads as protection.
  #
  # Not lost to the renumbering, which this used to guess at. 859 is a primary
  # key; that story's durable number is 973 ("My app has a working feedback
  # widget") and `test/spex/973_…` is on disk — the directory was looked up by
  # the wrong identifier, which is the id-versus-number confusion `f17113fc`
  # exists to end. Criterion 7321 has no row at all, so it went when that
  # story's criteria were rewritten. Measured across the project: 855 of 860
  # recorded `spec_path`s resolve, and the five that do not are deletions in
  # three unrelated stories. Nothing systematic ate the spex.
  #
  # What actually guards this is `graph_cache_test.exs`, "the fingerprint covers
  # what the delegate checkers read" — one test per input, which is the property
  # the spex was asserting end to end. Run that. Rebuilding the spex would be
  # better still.
  defp compute_and_publish(scope, ctx, config, preload_us \\ nil) do
    {nodes_us, {nodes, enriched_ctx}} =
      :timer.tc(fn -> compute_all_from_ctx(scope, ctx, config) end)

    {edges_us, edges} = :timer.tc(fn -> compute_edges(nodes, enriched_ctx, config) end)

    log_timing(scope, preload_us, nodes_us, edges_us, nodes, edges)

    scope
    |> GraphCache.publish(GraphFingerprint.compute(ctx, config), {nodes, edges})
    |> persist_projection(scope, enriched_ctx, nodes, edges)

    {nodes, edges}
  end

  # What the graph costs, split the way the work splits.
  #
  # `Predicates` exists on the premise that node computation dominates —
  # "4.4 seconds of `Enum` on a 3200-component project, against 34ms of
  # preload". That number came from one project at one time and there is no
  # instrumentation behind it, so whether converting the remaining checks to
  # queries is worth doing on any given project is currently unanswerable.
  #
  # Cheap to emit: this runs on a cache miss, not on a read, so it is one line
  # per genuine change rather than per render. The same cadence the round-trip
  # check already settled on.
  #
  # Logged rather than measured in a benchmark because the interesting case is
  # a real project's shape — 880 components with their files and problems — and
  # a synthetic graph would mostly measure the fixture.
  #
  # `preload_us` is nil when the caller loaded the context itself. That prints
  # "n/a" rather than a zero, because a zero here would read as "preloading is
  # free" — which is the specific claim this line exists to test.
  #
  # ## Do not compare two of these
  #
  # Seven consecutive measurements of the same workload on a developer laptop:
  # 2500, 1397, 1025, 2026, 1036, 1424, 1360ms. A 2× spread with nothing
  # changing but machine load, which on this box is whatever else is running —
  # a test suite alone moves it.
  #
  # So a single before/after pair proves nothing at this granularity, and two
  # optimizations tonight were credited and discredited by differences smaller
  # than the noise. What these numbers are good for is *attribution* — 614ms in
  # `kickoff_edge/4` against 3ms in the closure walk is a ratio no amount of
  # jitter explains — and for counts, which do not jitter at all. Prefer
  # "17,758 evaluations became 12" over "it got 148ms faster".
  defp log_timing(scope, preload_us, nodes_us, edges_us, nodes, edges) do
    ms = fn
      nil -> "n/a"
      us -> "#{round(us / 1000)}ms"
    end

    Logger.info(
      "[Requirements] graph computed for project #{inspect(scope.active_project_id)} — " <>
        "#{length(nodes)} nodes, #{length(edges)} edges; " <>
        "preload #{ms.(preload_us)}, nodes #{ms.(nodes_us)}, edges #{ms.(edges_us)}"
    )
  end

  # A cache hit is served from the rows. The payload is the fallback.
  #
  # That is the direction of the whole change: `requirements` and
  # `requirement_edges` are the read model, and `requirement_graphs.payload` is
  # what they replace. Serving the payload while writing rows nobody read proved
  # nothing — a projection is only trustworthy once something depends on it.
  #
  # The payload still wins in one case, and it is not a disagreement: no rows at
  # all for a project whose payload has nodes. That is a graph published before
  # this existed, or one whose row write failed, and serving an empty graph
  # would tell an agent it has no work.
  #
  # A genuine difference is served *from the rows* and logged loudly. Serving
  # the payload instead would hide the defect behind the thing being retired,
  # and leave the read model permanently unproven.
  #
  # Which is what the `rescue` that used to sit at the bottom of this function
  # did, for every failure rather than a named one. It cannot have been
  # protecting against the database: reaching here means `Preloader.load/1`,
  # `Configurations.get_or_create/1` and `GraphCache.fetch/2` have all already
  # returned in this same call, so a connection failure crashes upstream and
  # never arrives. What is left is a bug in `Projection.load/2` or
  # `Difference.describe/4` — exactly the defect the paragraph above says must
  # not be hidden behind the payload.
  defp served_graph(scope, ctx, {nodes, edges} = cached) do
    case Projection.load(scope, ctx) do
      {[], _} when nodes != [] ->
        Logger.warning(
          "[Requirements] projection is empty for a payload with #{length(nodes)} nodes " <>
            "— serving the payload. Rows were never written for this graph."
        )

        cached

      {read_nodes, read_edges} = projected ->
        case Difference.describe(read_nodes, read_edges, nodes, edges) do
          :none ->
            :ok

          description ->
            Logger.warning("[Requirements] " <> description <> " — serving the projection")
        end

        projected
    end
  end

  # Written behind the same fingerprint check that gates the payload. Readers
  # reach here on every render, so an unconditional upsert of every node per
  # page view is exactly what `publish/3` already refuses to do for one `bytea`.
  defp persist_projection(:unchanged, _scope, _ctx, _nodes, _edges), do: :ok

  # Writes the read model. Atomically, and loudly.
  #
  # This used to `rescue` every exception, log it at warning and answer `:ok`.
  # The reasoning was sound as far as it went — the computation's return value is
  # the agent's next instruction and is correct whether or not the rows were
  # written, so failing the call would turn a projection bug into a stopped
  # agent. What it produced was a projection that could silently stop being
  # written while every caller was told it had been, which is the state
  # `5b538c8b` was diagnosed in: rows missing for a whole checkout, and nothing
  # anywhere saying a write had failed.
  #
  # ## Why there is no error tuple here
  #
  # The first version of this fix wrapped the writes and matched on
  # `{:ok, _} | {:error, reason}`, on the claim that `Repo.transaction/1`
  # "answers those on its own". It does not. With a plain function it answers
  # `{:error, _}` only when `Repo.rollback/1` is called inside, and neither
  # `upsert_all/2` nor `replace_edges/3` calls it — a `Postgrex.Error` unwinds
  # the transaction and keeps going. So that branch was unreachable and its
  # logging never ran: a comment describing behaviour the code did not have,
  # which is the same species of untruth as the rescue it replaced.
  #
  # What is left is deliberate rather than a fallback. Every failure reachable
  # here is a constraint or schema error — a bug in ours — and the rest of this
  # module now treats those the same way, having found that catching them is how
  # a criterion stays green for months while the read model it asserts on is
  # never written. An expected condition earns a tuple; a bug earns a stack
  # trace.
  #
  # The transaction stays for the reason it was added: `upsert_all/2` and
  # `replace_edges/3` were two independent statements, so a failure between them
  # left nodes without their edges and the next read served that as the graph.
  defp persist_projection(:published, scope, ctx, nodes, edges) do
    {:ok, _} =
      Repo.transaction(fn ->
        ids_by_key = NodeRepository.upsert_all(scope, nodes)
        NodeRepository.replace_edges(scope, edges, ids_by_key)
      end)

    # Outside the transaction on purpose. Verification is a check *about* the
    # write, not part of it — running it inside would let a failed check roll
    # back rows that are correct, which is the opposite of what it is for.
    verify_round_trip(scope, ctx, nodes, edges)

    :ok
  end

  defp verify_round_trip(scope, ctx, nodes, edges) do
    {read_nodes, read_edges} = Projection.load(scope, ctx)

    case Difference.describe(read_nodes, read_edges, nodes, edges) do
      :none ->
        :ok

      description ->
        Logger.warning(
          "[Requirements] the projection does not round-trip — what was just " <>
            "written reads back different. " <> description
        )
    end
  end

  @doc """
  The published graph when it still matches current inputs, computing and
  publishing a fresh one when it does not.

  Returns `{{nodes, edges}, computed_at}`, where `computed_at` is `nil` for a
  graph computed just now and a `DateTime` for one served from the snapshot.
  Callers are expected to show that distinction rather than hide it.

  The saving is real but bounded: the preloader still runs, because deciding
  whether the snapshot is current means hashing the inputs. What a hit skips is
  node and edge computation, which is where the time actually goes — on a
  3200-component project, 34ms of preload against 4.4 seconds of compute.

  A hit certifies every input the graph is computed from, including what the
  delegate checkers read — six tables and four sets of working-copy files that
  the file sync does not track. `compute_and_publish/3` lists them.
  """
  @spec cached_graph(Scope.t()) :: {{[Requirement.t()], [edge()]}, DateTime.t() | nil}
  def cached_graph(%Scope{} = scope) do
    {graph, _actionable, computed_at} = cached_graph_with_actionable(scope)
    {graph, computed_at}
  end

  @doc """
  `cached_graph/1` plus the actionable set, for readers that want both without
  paying for the preload twice.

  Returns `{{nodes, edges}, actionable, computed_at}`.
  """
  @spec cached_graph_with_actionable(Scope.t()) ::
          {{[Requirement.t()], [edge()]}, [Requirement.t()], DateTime.t() | nil}
  def cached_graph_with_actionable(%Scope{} = scope) do
    with {:ok, ctx} <- Preloader.load(scope) do
      cached_graph_with_actionable(scope, ctx)
    end
  end

  defp cached_graph_with_actionable(scope, ctx) do
    config = CodeMySpec.Configurations.get_or_create(scope)

    {graph, computed_at} =
      case GraphCache.fetch(scope, GraphFingerprint.compute(ctx, config)) do
        {:ok, cached, at} -> {served_graph(scope, ctx, cached), at}
        :miss -> {compute_and_publish(scope, ctx, config), nil}
      end

    {nodes, edges} = graph

    # The un-enriched ctx, as in `next_actionable/1`: `actionable_from/3` reads
    # `ctx.components` and `ctx.stories`, both of which the preloader supplies.
    {graph, actionable_from(nodes, edges, ctx), computed_at}
  end

  @doc """
  Returns the next actionable requirements — unsatisfied nodes where
  every incoming edge is satisfied.

  Component requirements without inherited priority (no direct story
  link, no inheritance via surface deps, no inheritance via parent
  chain) are filtered out. Without a business driver, surfacing them
  asks the agent to implement components that may be deleted,
  relinked, or merged by the architecture task. Story-driven
  components and their priority-inheriting descendants stay
  surfaced.
  """
  @spec next_actionable(Scope.t()) :: [Requirement.t()]
  def next_actionable(%Scope{} = scope) do
    {_graph, actionable, _computed_at} = cached_graph_with_actionable(scope)
    actionable
  end

  @doc """
  Compute nodes, edges, and actionable nodes in a single pass.

  Equivalent to calling `compute_graph/1` and `next_actionable/1`
  separately, but shares preload + graph compute work.
  """
  @spec compute_graph_with_actionable(Scope.t()) ::
          {[Requirement.t()], [edge()], [Requirement.t()]}
  def compute_graph_with_actionable(%Scope{} = scope) do
    {result, _metrics} = compute_graph_with_actionable_metrics(scope)
    result
  end

  @doc """
  Same as `compute_graph_with_actionable/1` but also returns per-phase
  timings (in milliseconds) so callers can surface them for debugging
  or progress reporting.
  """
  @spec compute_graph_with_actionable_metrics(Scope.t()) ::
          {{[Requirement.t()], [edge()], [Requirement.t()]}, %{atom() => integer()}}
  def compute_graph_with_actionable_metrics(%Scope{} = scope) do
    {us_preload, {:ok, ctx}} = :timer.tc(fn -> Preloader.load(scope) end)
    {us_config, config} = :timer.tc(fn -> CodeMySpec.Configurations.get_or_create(scope) end)
    {us_nodes, {nodes, ctx}} = :timer.tc(fn -> compute_all_from_ctx(scope, ctx, config) end)
    {us_edges, edges} = :timer.tc(fn -> compute_edges(nodes, ctx, config) end)
    {us_actionable, actionable} = :timer.tc(fn -> actionable_from(nodes, edges, ctx) end)

    metrics = %{
      preload_ms: div(us_preload, 1000),
      config_ms: div(us_config, 1000),
      compute_nodes_ms: div(us_nodes, 1000),
      compute_edges_ms: div(us_edges, 1000),
      actionable_ms: div(us_actionable, 1000),
      node_count: length(nodes),
      edge_count: length(edges)
    }

    {{nodes, edges, actionable}, metrics}
  end

  defp actionable_from(nodes, edges, ctx) do
    satisfaction_map =
      Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    blocked_descendants = compute_blocked_descendants(edges, satisfaction_map)

    component_priority = build_component_priority_map(ctx)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        not untethered_component?(n, component_priority) and
        not MapSet.member?(blocked_descendants, node_key(n))
    end)
    |> sort_by_story_priority(ctx)
  end

  defp untethered_component?(%{entity_type: "component", entity_id: id}, component_priority) do
    not Map.has_key?(component_priority, id)
  end

  defp untethered_component?(_node, _component_priority), do: false

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()] | {:error, :no_working_copy}
  def compute_all(%Scope{} = scope) do
    with {:ok, ctx} <- Preloader.load(scope) do
      config = CodeMySpec.Configurations.get_or_create(scope)
      {nodes, _edges} = compute_and_publish(scope, ctx, config)
      nodes
    end
  end

  # Satisfaction is a local property — each node's `satisfied` field is the
  # result of its own leaf check, computed once in `compute_all_from_ctx`
  # and never mutated by graph context. Story 562: locally-truthful state
  # plus prerequisite-driven actionability replaced the cascading clamp pass.
  # Upstream gating happens at `actionable_from` time, not on the node.

  # -- Edge computation --

  defp compute_edges(nodes, ctx, config) do
    # Template edges are computed during instantiation (stored in ctx)
    template_edges = ctx[:template_edges] || []

    node_keys = MapSet.new(nodes, &Topology.node_key/1)

    {generate_us, by_source} =
      :timer.tc(fn ->
        [
          {"template", template_edges},
          {"project→story", project_to_story_edges(ctx)},
          {"component tree", component_tree_edges(ctx, config)},
          {"cross-context", cross_context_dependency_edges(ctx, config)},
          {"story→project", story_to_project_edges(ctx)}
        ]
      end)

    generated = Enum.flat_map(by_source, fn {_name, edges} -> edges end)

    {filter_us, kept} =
      :timer.tc(fn ->
        Enum.filter(generated, fn %{from: f, to: t} ->
          MapSet.member?(node_keys, f) and MapSet.member?(node_keys, t)
        end)
      end)

    # Deduplicate before reducing, not after.
    #
    # `NodeRepository.replace_edges/3` already calls `Enum.uniq/1` on these, so
    # duplicates were known about — they were just being carried through the
    # expensive step first. A duplicate edge is the same edge: reachability
    # cannot change, so this is semantics-preserving by construction.
    {dedup_us, unique} = :timer.tc(fn -> Enum.uniq(kept) end)

    {reduce_us, reduced} = :timer.tc(fn -> Topology.transitive_reduction(unique) end)

    log_edge_timing(generated, unique, reduced, generate_us, filter_us + dedup_us, reduce_us)
    log_edge_sources(by_source)

    reduced
  end

  # Which third of the edge phase actually costs.
  #
  # The outer timing said "edges 2500ms" against "nodes 69ms", which was enough
  # to redirect the optimization effort but not enough to act on: generating
  # edges, discarding the ones whose endpoints are not nodes, and reducing them
  # transitively are three different problems with three different fixes.
  #
  # `transitive_reduction/1` has been optimized once already — a comment there
  # records 471ms on a 1045-node graph before the bitset rewrite — so it is the
  # obvious suspect and therefore exactly the thing not to assume.
  #
  # The counts matter as much as the times. A large gap between generated and
  # kept means the generators are producing edges for nodes that do not exist,
  # which is work thrown away rather than work needed.
  # Which generator produces the duplicates.
  #
  # 42% of generated edges were duplicates — 32,973 down to 19,132 — and
  # deduplicating them before the reduction was worth ~370ms. That fixed the
  # symptom. Producing 13,841 edges in order to throw them away is still work
  # nobody needs, and the fix belongs in whichever generator emits the same edge
  # more than once rather than in a wider `uniq` downstream.
  #
  # Per-source counts because the generators have genuinely different shapes:
  # one walks each story's transitive dependency closure, another fans out over
  # component children. A closure walk that revisits a node by every path that
  # reaches it produces duplicates proportional to path count, which is the
  # explanation to confirm or rule out first.
  defp log_edge_sources(by_source) do
    detail =
      Enum.map_join(by_source, ", ", fn {name, edges} ->
        total = length(edges)
        unique = edges |> Enum.uniq() |> length()

        case total - unique do
          0 -> "#{name} #{total}"
          dupes -> "#{name} #{total} (#{dupes} dupe)"
        end
      end)

    Logger.info("[Requirements] edge sources — " <> detail)
    log_duplicate_shape(by_source)
  end

  # How the duplicates are distributed, not just how many there are.
  #
  # 13,433 of them come from the component tree, and the count alone does not
  # say which generator behaviour produces them. Multiplicity does: mostly ×2
  # means two paths reach the same edge once each — a parent fanning out to a
  # child that is itself in the closure emitting for itself — while a long tail
  # of high-multiplicity edges means many stories share one closure and every
  # one of them re-emits it.
  #
  # Those want different fixes, so the distribution is the thing to look at
  # before changing how the fan-out works.
  defp log_duplicate_shape(by_source) do
    {_, edges} = Enum.find(by_source, {nil, []}, fn {name, _} -> name == "component tree" end)

    counts =
      edges
      |> Enum.frequencies()
      |> Enum.reject(fn {_edge, n} -> n == 1 end)

    case counts do
      [] ->
        :ok

      _ ->
        by_multiplicity =
          counts
          |> Enum.frequencies_by(fn {_edge, n} -> n end)
          |> Enum.sort()
          |> Enum.map_join(", ", fn {n, edges} -> "×#{n}: #{edges}" end)

        {worst, worst_n} = Enum.max_by(counts, &elem(&1, 1))

        Logger.info(
          "[Requirements] component tree duplicates — #{length(counts)} distinct edges " <>
            "repeat (#{by_multiplicity}); worst #{inspect(worst.from)} → " <>
            "#{inspect(worst.to)} ×#{worst_n}"
        )
    end
  end

  defp log_edge_timing(generated, kept, reduced, generate_us, filter_us, reduce_us) do
    ms = &round(&1 / 1000)

    Logger.info(
      "[Requirements] edges — #{length(generated)} generated, #{length(kept)} unique, " <>
        "#{length(reduced)} after reduction; generate #{ms.(generate_us)}ms, " <>
        "filter+dedup #{ms.(filter_us)}ms, reduce #{ms.(reduce_us)}ms"
    )
  end

  # Cross-entity: story ↔ surface tree.
  #
  # Kickoff edges (`bdd_specs_exist → first work item`) span the
  # surface AND every component in its transitive cross-context
  # dependency closure. Transitive reduction collapses these to the
  # deepest dep(s) — the story's outgoing edge ends up at whatever
  # has to be done first in the dep chain.
  #
  # Kickoff target dispatch follows the node_scope of the first
  # surviving def for the kickoff component's type:
  # - `:parent` / `:self` → land on the kickoff component's own node
  #   (the natural starting point — e.g. parent.spec_file under the
  #   default config for a context surface)
  # - `:child` → fan out to every direct child whose own type
  #   template includes that def's name (the symmetric counterpart
  #   of `container_exit_edges`; required when the parent's chain
  #   has been filtered down to nothing but child-scoped work, as
  #   happens when require_specs/reviews/tests are all disabled)
  #
  # The exit edge stays at the surface's terminal — the story's done
  # when the surface is done; deps reach the exit transitively. For
  # container surfaces it fans in from each child's terminal.
  # `children_by_parent` is built once here rather than per story.
  #
  # `expand_with_parent_chain_descendants/2` needs it and used to group all of
  # `ctx.components` on every call — once per story, so 93 × 880 components on
  # this project to rebuild an identical map 93 times. It depends only on the
  # context, so the loop was the wrong place for it.
  #
  # It is worth almost nothing, and that is the useful part. Generation measured
  # 571ms before and 563ms after: 81,840 filter-and-group operations cost about
  # 8ms, so whoever looks here next for the remaining ~560ms should look past
  # this at `kickoff_edge/4` and `transitive_dep_closure/2`, which between them
  # produce 31,257 of the 32,973 edges.
  #
  # Kept because it is strictly less work for the same result, not because it
  # fixed anything.
  defp component_tree_edges(ctx, config) do
    ctx =
      ctx
      |> Map.put(:children_by_parent, children_by_parent(ctx))
      |> Map.put(:first_def_by_type, first_def_by_type(ctx, config))

    {edges, timing} =
      ctx.stories
      |> Enum.filter(&(&1.component_id != nil))
      |> Enum.map_reduce(%{closure: 0, expand: 0, kickoff: 0, exit: 0, components: 0}, fn story,
                                                                                          acc ->
        story_chain_edges(story, ctx, config, acc)
      end)

    log_component_tree_timing(timing)
    List.flatten(edges)
  end

  # Inside the 95%.
  #
  # `component_tree_edges/2` produces 31,257 of 32,973 edges and 13,433 of the
  # duplicates, and generation is ~563ms of a ~1030ms edge phase. Twice tonight
  # a guess about where that time goes has been wrong — first that node
  # computation dominated when it was edges, then that rebuilding
  # `children_by_parent` per story mattered when it was worth 8ms — so this
  # splits the four things a story chain does instead of guessing a third time.
  #
  # `components` is the total kickoff fan-out across stories: the number of
  # components each story's closure expands to, summed. If that is large
  # relative to the component count, the closure walk is the shape to attack
  # rather than the per-edge work.
  defp log_component_tree_timing(t) do
    ms = &round(&1 / 1000)

    Logger.info(
      "[Requirements] component tree — closure #{ms.(t.closure)}ms, " <>
        "expand #{ms.(t.expand)}ms, kickoff #{ms.(t.kickoff)}ms, exit #{ms.(t.exit)}ms; " <>
        "#{t.components} kickoff components across stories"
    )
  end

  defp children_by_parent(ctx) do
    ctx.components
    |> Enum.filter(& &1.parent_component_id)
    |> Enum.group_by(& &1.parent_component_id)
  end

  defp story_chain_edges(story, ctx, config, acc) do
    case Map.get(ctx.components_by_id, story.component_id) do
      nil ->
        {[], acc}

      surface ->
        {closure_us, closure} = :timer.tc(fn -> transitive_dep_closure(surface, ctx) end)

        {expand_us, kickoff_components} =
          :timer.tc(fn -> expand_with_parent_chain_descendants(closure, ctx) end)

        kickoff_ids = MapSet.new(kickoff_components, & &1.id)

        {kickoff_us, kickoff_edges} =
          :timer.tc(fn ->
            Enum.flat_map(kickoff_components, &kickoff_edge(&1, story, config, ctx, kickoff_ids))
          end)

        {exit_us, exit_edges} =
          :timer.tc(fn -> surface_exit_edge(surface, story, ctx, config) end)

        acc = %{
          closure: acc.closure + closure_us,
          expand: acc.expand + expand_us,
          kickoff: acc.kickoff + kickoff_us,
          exit: acc.exit + exit_us,
          components: acc.components + length(kickoff_components)
        }

        {kickoff_edges ++ exit_edges, acc}
    end
  end

  # Expand a list of components to include every parent_component_id
  # descendant. Priority cascades through parent chains (story 561
  # rule f24fa177, criterion 6259); the kickoff fan-out should mirror
  # that cascade so descendants of cross-context deps are gated by
  # upstream work the same way their priority-source ancestor is.
  # Without this expansion, a non-container intermediate (e.g.
  # `Environments.Cli`) leaves its descendants (`Cli.TmuxAdapter`)
  # priority-tethered but edge-orphaned — actionable even when the
  # whole project chain is unsatisfied. Container-template chains
  # add their own edges; `Topology.transitive_reduction/1` removes
  # the resulting redundancies downstream.
  defp expand_with_parent_chain_descendants(components, ctx) do
    children_by_parent = ctx[:children_by_parent] || children_by_parent(ctx)

    components
    |> Enum.flat_map(&[&1 | descendants_of(&1, children_by_parent, MapSet.new())])
    |> Enum.uniq_by(& &1.id)
  end

  defp descendants_of(component, children_by_parent, visited) do
    if MapSet.member?(visited, component.id) do
      []
    else
      visited = MapSet.put(visited, component.id)
      children = Map.get(children_by_parent, component.id, [])

      children ++
        Enum.flat_map(children, &descendants_of(&1, children_by_parent, visited))
    end
  end

  defp kickoff_edge(comp, story, config, ctx, kickoff_ids) do
    case first_def_for(comp.type, config, ctx) do
      nil ->
        []

      %{node_scope: :child, name: name} ->
        comp
        |> direct_children(ctx)
        |> Enum.filter(&child_supports_def_name?(&1, name))
        |> Enum.reject(&emits_for_itself?(&1, name, config, ctx, kickoff_ids))
        |> Enum.map(fn child ->
          %{
            from: {"story", story.id, "bdd_specs_exist"},
            to: {"component", child.id, name}
          }
        end)

      %{name: name} ->
        [
          %{
            from: {"story", story.id, "bdd_specs_exist"},
            to: {"component", comp.id, name}
          }
        ]
    end
  end

  # A child that is itself in the kickoff closure and lands on its own node
  # emits this exact edge already, so the parent's fan-out to it is the same
  # edge a second time.
  #
  # That is every duplicate the component tree produced: 13,433 of them,
  # uniformly ×2, none at ×3 or higher. A uniform ×2 is the signature of two
  # paths reaching one edge once each, which is what this suppresses.
  #
  # Both conditions are load-bearing. A child outside the closure is not
  # emitting anything, and a child whose own first def is `:child`-scoped fans
  # out to *its* children instead of landing on itself — in either case the
  # parent's edge is the only one and dropping it would lose it.
  #
  # Nothing about the graph changes: the duplicates were exact repeats and
  # `Enum.uniq/1` already removed them before the transitive reduction. This
  # stops building what was being thrown away.
  defp emits_for_itself?(child, name, config, ctx, kickoff_ids) do
    MapSet.member?(kickoff_ids, child.id) and
      case first_def_for(child.type, config, ctx) do
        %{node_scope: :child} -> false
        %{name: ^name} -> true
        _ -> false
      end
  end

  defp child_supports_def_name?(child, name) do
    child.type
    |> RequirementsRegistry.get_requirements_for_type()
    |> Enum.any?(&(&1.name == name))
  end

  # bdd_specs_passing is gated on the LEAVES of the surface's
  # orchestration tree:
  # - leaf surface (template has no :child defs): the surface's own
  #   last :self def feeds bdd_specs_passing.
  # - container surface (template has :child defs): each direct
  #   child's terminal feeds bdd_specs_passing. Sibling children
  #   with cross-context deps collapse via transitive reduction —
  #   only the deepest leaf survives.
  #
  # The gate then feeds qa_complete via the intra-story prerequisite
  # edge, so a story cannot reach a QA sub-agent before its own specs
  # have gone green. bab2f792 pointed these terminals straight at
  # qa_complete when the gate was removed; this puts the seam back.
  defp surface_exit_edge(surface, story, ctx, config) do
    if RequirementsRegistry.has_children?(surface.type) do
      container_exit_edges(surface, story, ctx, config)
    else
      leaf_exit_edge(surface, story, config)
    end
  end

  defp leaf_exit_edge(surface, story, config) do
    case last_filtered_def(surface.type, config) do
      nil ->
        []

      terminal ->
        [
          %{
            from: {"component", surface.id, terminal.name},
            to: {"story", story.id, "bdd_specs_passing"}
          }
        ]
    end
  end

  defp container_exit_edges(surface, story, ctx, config) do
    surface
    |> direct_children(ctx)
    |> Enum.flat_map(fn child ->
      case child_terminal_name(surface.type, child.type, config) do
        nil ->
          []

        name ->
          [
            %{
              from: {"component", child.id, name},
              to: {"story", story.id, "bdd_specs_passing"}
            }
          ]
      end
    end)
  end

  defp direct_children(parent, ctx) do
    Map.get(ctx.children_by_parent, parent.id, [])
  end

  defp child_terminal_name(parent_type, child_type, config) do
    child_own_names =
      child_type
      |> RequirementsRegistry.get_requirements_for_type()
      |> MapSet.new(& &1.name)

    parent_type
    |> RequirementsRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> Enum.filter(&(&1.node_scope == :child and &1.name in child_own_names))
    |> List.last()
    |> case do
      nil -> nil
      def -> def.name
    end
  end

  # `first_filtered_def/2` keyed by type, computed once per graph.
  #
  # It is a pure function of `(type, config)` — a registry lookup and four
  # config filters — and there are about a dozen component types. It was being
  # evaluated once per kickoff component: 17,758 times on this project, for a
  # dozen distinct answers.
  #
  # Measured, not guessed: the four-way split put 614ms of a 1,030ms edge phase
  # inside `kickoff_edge/4`, at ~35µs a call, which is far too slow for building
  # two-field maps. `direct_children/2` was already a map lookup, leaving this as
  # the only per-call work that scaled with anything.
  defp first_def_by_type(ctx, config) do
    ctx.components
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Map.new(&{&1, first_filtered_def(&1, config)})
  end

  defp first_def_for(type, config, ctx) do
    case ctx[:first_def_by_type] do
      nil -> first_filtered_def(type, config)
      by_type -> Map.get_lazy(by_type, type, fn -> first_filtered_def(type, config) end)
    end
  end

  defp first_filtered_def(type, config) do
    type
    |> RequirementsRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.first()
  end

  defp last_filtered_def(type, config) do
    type
    |> RequirementsRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.last()
  end

  defp transitive_dep_closure(start_component, ctx) do
    [start_component.id]
    |> bfs_dep_ids(MapSet.new(), ctx)
    |> Enum.map(&Map.get(ctx.components_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp bfs_dep_ids([], visited, _ctx), do: visited

  defp bfs_dep_ids([id | rest], visited, ctx) do
    if MapSet.member?(visited, id) do
      bfs_dep_ids(rest, visited, ctx)
    else
      visited = MapSet.put(visited, id)

      new_dep_ids =
        case Map.get(ctx.components_by_id, id) do
          nil -> []
          comp -> comp |> component_deps() |> Enum.map(& &1.id)
        end

      bfs_dep_ids(rest ++ new_dep_ids, visited, ctx)
    end
  end

  defp find_def(definitions, name) do
    Enum.find(definitions, &(&1.name == name))
  end

  # Cross-entity: story.qa_complete → project.qa_journey_plan.
  # The project-level fan-in: every story's QA completion gates the
  # project's QA journey chain. This edge is the structural seam the
  # graph projector uses to lay late_project nodes against the bottom
  # band — keep a story→project fan-in even if the target node changes.
  defp story_to_project_edges(ctx) do
    project_id =
      case ctx.stories do
        [story | _] -> story.project_id
        _ -> nil
      end

    if project_id do
      Enum.map(ctx.stories, fn story ->
        %{
          from: {"story", story.id, "qa_complete"},
          to: {"project", project_id, "qa_journey_plan"}
        }
      end)
    else
      []
    end
  end

  # Cross-context dependency edges.
  # Sibling deps (same parent) are handled by template instantiation.
  # Cross-context deps gate the dependent's first requirement.
  defp cross_context_dependency_edges(ctx, config) do
    Enum.flat_map(ctx.components, &edges_from_component_deps(&1, ctx, config))
  end

  defp edges_from_component_deps(comp, ctx, config) do
    comp
    |> component_deps()
    |> Enum.flat_map(&cross_context_edge_for_dep(&1, comp, ctx, config))
  end

  defp component_deps(comp) do
    case comp.dependencies do
      %Ecto.Association.NotLoaded{} -> []
      deps when is_list(deps) -> deps
      _ -> []
    end
  end

  defp cross_context_edge_for_dep(dep, comp, ctx, config) do
    with %_{} = dep_comp <- Map.get(ctx.components_by_id, dep.id),
         dep_terminal when not is_nil(dep_terminal) <- dep_terminal_def(dep_comp, config),
         target when not is_nil(target) <- cross_context_target(comp, dep_comp, config),
         false <- skip_cross_context?(comp, dep_comp) do
      [
        %{
          from: {"component", dep_comp.id, dep_terminal.name},
          to: {"component", comp.id, target.name}
        }
      ]
    else
      _ -> []
    end
  end

  defp dep_terminal_def(dep_comp, config) do
    dep_comp.type
    |> RequirementsRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.last()
  end

  defp cross_context_target(comp, dep_comp, config) do
    comp_defs =
      comp.type
      |> RequirementsRegistry.get_requirements_for_type()
      |> filter_definitions_by_config(config)

    if siblings?(comp, dep_comp),
      do: find_def(comp_defs, "implementation_file"),
      else: List.first(comp_defs)
  end

  defp siblings?(comp, dep_comp) do
    comp.parent_component_id != nil and
      comp.parent_component_id == dep_comp.parent_component_id
  end

  # Skip cross-context edges for child components — parent_child_edges
  # propagates ordering from the parent context to its children.
  defp skip_cross_context?(comp, dep_comp) do
    not siblings?(comp, dep_comp) and comp.parent_component_id != nil
  end

  # Cross-entity: project.qa_setup → story.component_linked
  defp project_to_story_edges(ctx) do
    project_id = ctx.stories |> List.first() |> then(fn s -> s && s.project_id end)

    if project_id && ctx.stories != [] do
      Enum.map(ctx.stories, fn story ->
        %{from: {"project", project_id, "qa_setup"}, to: {"story", story.id, "component_linked"}}
      end)
    else
      []
    end
  end

  # -- Actionability --

  # Compute the set of node keys whose actionability is blocked by an
  # unsatisfied upstream node. A node is blocked iff any node reachable
  # from it via reverse-edge traversal (i.e. any transitive prerequisite)
  # is unsatisfied. Walks the DAG forward from every unsatisfied node and
  # marks every strict descendant as blocked.
  #
  # This is the single-hop → transitive upgrade that closes the
  # cross-scope gating gap: when a project-chain requirement reopens,
  # the unsatisfaction propagates through `project.qa_setup →
  # story.component_linked → story.bdd_specs_exist → component.first_req`
  # so component work disappears from the actionable list even though
  # every locally-satisfied node along the chain still reports
  # `satisfied: true`.
  defp compute_blocked_descendants(edges, satisfaction_map) do
    outgoing =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge.to], &[edge.to | &1])
      end)

    satisfaction_map
    |> Enum.filter(fn {_key, satisfied} -> not satisfied end)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.reduce(MapSet.new(), fn key, acc ->
      propagate_downstream(Map.get(outgoing, key, []), outgoing, acc)
    end)
  end

  defp propagate_downstream([], _outgoing, acc), do: acc

  defp propagate_downstream([key | rest], outgoing, acc) do
    if MapSet.member?(acc, key) do
      propagate_downstream(rest, outgoing, acc)
    else
      acc = MapSet.put(acc, key)
      children = Map.get(outgoing, key, [])
      propagate_downstream(children ++ rest, outgoing, acc)
    end
  end

  defp node_key(n), do: {n.entity_type, n.entity_id, n.name}

  # -- Node computation --

  defp compute_all_from_ctx(scope, ctx, config) do
    {component_nodes, component_edges} = instantiate_component_graphs(scope, ctx, config)
    {story_nodes, story_edges} = compute_story_nodes(scope, ctx, config)
    {project_nodes, project_edges} = compute_project_nodes(scope, ctx, config)

    all_nodes = project_nodes ++ story_nodes ++ component_nodes
    all_template_edges = component_edges ++ story_edges ++ project_edges

    ctx = Map.put(ctx, :template_edges, all_template_edges)

    {all_nodes, ctx}
  end

  # Instantiate graph templates for all components.
  # For components with children (contexts), stamps out :child nodes per child.
  # Returns {nodes, edges} where edges are resolved from template IDs.
  # The template is filtered by the project configuration up front so disabled
  # artifact types (specs, reviews, tests) are stripped from both nodes and edges.
  defp instantiate_component_graphs(scope, ctx, config) do
    # Only context-shaped types (templates with :child scope defs) own
    # their nested components for template purposes. A component nested
    # under a non-context parent (e.g. a context whose namespace happens
    # to live under an `infrastructure` umbrella like `MarketMySpec`) is
    # still top-level and must run its own template — otherwise every
    # component below the umbrella gets dropped from the requirement
    # graph and the project shows 0/0 everywhere.
    container_ids =
      ctx.components
      |> Enum.filter(&RequirementsRegistry.has_children?(&1.type))
      |> MapSet.new(& &1.id)

    children_by_parent =
      ctx.components
      |> Enum.filter(fn c ->
        c.parent_component_id && MapSet.member?(container_ids, c.parent_component_id)
      end)
      |> Enum.group_by(& &1.parent_component_id)

    child_ids =
      ctx.components
      |> Enum.filter(fn c ->
        c.parent_component_id && MapSet.member?(container_ids, c.parent_component_id)
      end)
      |> MapSet.new(& &1.id)

    ctx.components
    |> Enum.reject(fn c -> MapSet.member?(child_ids, c.id) end)
    |> Enum.flat_map_reduce([], fn component, all_edges ->
      children = Map.get(children_by_parent, component.id, [])

      original_template = RequirementDefinitionData.graph_for_type(component.type)
      filtered_template = filter_definitions_by_config(original_template, config)

      {us, {nodes, edges}} =
        :timer.tc(fn ->
          instantiate_template(
            scope,
            ctx,
            filtered_template,
            original_template,
            component,
            children
          )
        end)

      log_slow_component(component, children, nodes, us)

      {nodes, all_edges ++ edges}
    end)
  end

  @slow_component_threshold_us 50_000

  defp log_slow_component(component, children, nodes, us)
       when us >= @slow_component_threshold_us do
    require Logger

    Logger.info(
      "[RequirementGraph] slow component: #{component.module_name} (#{component.type}) " <>
        "took #{div(us, 1000)}ms — #{length(children)} children, #{length(nodes)} nodes"
    )
  end

  defp log_slow_component(_component, _children, _nodes, _us), do: :ok

  # Instantiate a single graph template for a component + its children.
  # `filtered_template` is the template with config-disabled artifact types
  # rejected. `original_template` is the unfiltered template — used by
  # `build_template_edges/3` to walk through filtered or empty-scope
  # prerequisites and splice the chain through to a surviving ancestor
  # whose node actually exists in the rendered graph.
  defp instantiate_template(scope, ctx, filtered_template, original_template, component, children) do
    parent_defs = Enum.filter(filtered_template, &(&1.node_scope == :parent))
    child_defs = Enum.filter(filtered_template, &(&1.node_scope == :child))
    self_defs = Enum.filter(filtered_template, &(&1.node_scope == :self))

    # Build ID → node_key map for edge resolution
    id_map = build_id_map(filtered_template, component, children)

    # Instantiate parent nodes (once for the component)
    parent_nodes =
      Enum.map(parent_defs, fn def ->
        build_node(scope, ctx, def, component)
      end)

    # Instantiate self nodes (standalone, no parent/child)
    self_nodes =
      Enum.map(self_defs, fn def ->
        build_node(scope, ctx, def, component)
      end)

    # Instantiate child nodes (once per child per child_def),
    # filtering to only defs the child's type supports and
    # threading the parent entity for orchestration grouping.
    child_nodes =
      Enum.flat_map(children, fn child ->
        child_defs
        |> filter_defs_for_child_type(child.type)
        |> Enum.map(fn def ->
          build_node(scope, ctx, def, child, component)
        end)
      end)

    all_nodes = parent_nodes ++ self_nodes ++ child_nodes

    # Build edges from template prerequisites, splicing through filtered or
    # empty-scope ancestors using the original template as the walk graph.
    edges = build_template_edges(filtered_template, id_map, original_template)

    {all_nodes, edges}
  end

  # Map template IDs to real node keys.
  # :parent and :self nodes map to the component itself.
  # :child nodes map to EACH child — one key per child per template ID.
  defp build_id_map(template, component, children) do
    template
    |> Enum.flat_map(&id_map_entries(&1, component, children))
    |> Map.new()
  end

  defp id_map_entries(def, component, _children) when def.node_scope in [:parent, :self] do
    [{def.id, [{"component", component.id, def.name}]}]
  end

  defp id_map_entries(def, _component, children) do
    keys = Enum.map(children, &{"component", &1.id, def.name})
    [{def.id, keys}]
  end

  # Build edges by resolving template prerequisite IDs to real node keys.
  #
  # When a prerequisite was filtered out by configuration (the def is
  # absent from `id_map`), the chain is spliced: walk the original
  # template's prereq DAG backwards until a def that survived filtering
  # is reached. Edges from the surviving ancestor land on the surviving
  # descendant, keeping the downstream node correctly gated on real
  # upstream work rather than silently disconnected.
  #
  # Surviving defs whose scope has no instances (e.g. a `:child` def
  # for a component with no children) are kept as-is — they produce
  # no edges, matching the pre-filter no-children topology where
  # nothing was gated through that scope either.
  #
  # Edge semantics depend on the node_scope of source and target:
  # - child → child (same scope): zip by child (each child's node depends on its OWN prereq)
  # - parent → child: fan-out (one parent node → each child's node)
  # - child → parent: fan-in (each child's node → one parent node)
  # - same scope single: direct edge
  defp build_template_edges(filtered_template, id_map, original_template \\ nil) do
    walk_template = original_template || filtered_template
    by_id = Map.new(walk_template, &{&1.id, &1})
    scope_by_id = Map.new(walk_template, &{&1.id, &1.node_scope})

    Enum.flat_map(filtered_template, &edges_for_def(&1, by_id, id_map, scope_by_id))
  end

  defp edges_for_def(def, by_id, id_map, scope_by_id) do
    to_keys = Map.get(id_map, def.id, [])

    Enum.flat_map(def.prerequisites, fn prereq_id ->
      prereq_id
      |> walk_past_filtered(by_id, id_map, MapSet.new())
      |> Enum.flat_map(&edges_from_effective_prereq(&1, def, to_keys, id_map, scope_by_id))
    end)
  end

  defp edges_from_effective_prereq(eff_id, def, to_keys, id_map, scope_by_id) do
    from_keys = Map.get(id_map, eff_id, [])
    from_scope = Map.get(scope_by_id, eff_id)
    build_edges_for_scopes(from_scope, def.node_scope, from_keys, to_keys)
  end

  # Walk the original template backwards through any defs that were
  # filtered out by config (and thus have no entry in `id_map`).
  # The walk terminates the moment it reaches a def that survived
  # filtering — even if that def's scope has no instances. This keeps
  # the splice scoped to the configuration-induced gap, leaving the
  # natural no-children chain shape unchanged for unfiltered runs.
  defp walk_past_filtered(prereq_id, by_id, id_map, visited) do
    cond do
      MapSet.member?(visited, prereq_id) ->
        []

      Map.has_key?(id_map, prereq_id) ->
        [prereq_id]

      true ->
        visited = MapSet.put(visited, prereq_id)

        case Map.get(by_id, prereq_id) do
          nil ->
            []

          def ->
            def.prerequisites
            |> Enum.flat_map(&walk_past_filtered(&1, by_id, id_map, visited))
            |> Enum.uniq()
        end
    end
  end

  # Both child: pair by position (each child connects to itself)
  defp build_edges_for_scopes(:child, :child, from_keys, to_keys) do
    Enum.zip(from_keys, to_keys)
    |> Enum.map(fn {from, to} -> %{from: from, to: to} end)
  end

  # Cross-scope or single: cartesian product (fan-in, fan-out, or direct)
  defp build_edges_for_scopes(_from_scope, _to_scope, from_keys, to_keys) do
    for from_key <- from_keys, to_key <- to_keys, from_key != to_key do
      %{from: from_key, to: to_key}
    end
  end

  defp build_node(scope, ctx, definition, entity, parent \\ nil) do
    files = Map.get(ctx.files_by_component, entity.id, [])
    result = RequirementCalculator.compute_one(scope, entity, definition, files, ctx)

    # Parent resolution: child nodes use the explicit parent.
    # Parent/self-scope nodes self-parent when orchestrated (so they group
    # with child nodes under the same context header).
    {parent_id, parent_name} =
      cond do
        parent -> {parent.id, parent.module_name}
        definition.orchestrated_by -> {entity.id, entity.module_name}
        true -> {nil, nil}
      end

    %Requirement{
      entity_type: "component",
      entity_id: entity.id,
      entity_name: entity.module_name,
      name: definition.name,
      description: definition.description,
      satisfied: result.satisfied,
      satisfied_by: definition.satisfied_by,
      scope: definition.scope || :local,
      execution_type: definition.execution_type || :main_agent,
      validation_type: definition.validation_type || :automatic,
      orchestrated_by: definition.orchestrated_by,
      render_command_always?: definition.render_command_always? || false,
      role: definition.role,
      parent_entity_id: parent_id,
      parent_entity_name: parent_name,
      prerequisites: [],
      details: Requirement.normalize_details(result.details)
    }
  end

  # Only stamp child_defs whose names exist in the child's own graph template.
  defp filter_defs_for_child_type(defs, child_type) do
    allowed =
      child_type
      |> RequirementDefinitionData.graph_for_type()
      |> MapSet.new(& &1.name)

    Enum.filter(defs, &(&1.name in allowed))
  end

  defp compute_story_nodes(scope, ctx, config) do
    # Only the devops filter applies to story templates — the
    # specs/reviews/tests filters are component-scoped by design
    # (require_specs must not strip three_amigos/bdd requirements).
    # devops: :off drops the deploy requirement from every story.
    template = maybe_filter_devops(RequirementDefinitionData.story_graph(), config)
    project = scope.active_project

    {nodes, edges} =
      Enum.flat_map_reduce(ctx.stories, [], fn story, all_edges ->
        files = Map.get(ctx.files_by_story, story.id, [])
        id_map = Map.new(template, fn d -> {d.id, [{"story", story.id, d.name}]} end)

        nodes =
          Enum.map(template, fn definition ->
            result = RequirementCalculator.compute_one(scope, story, definition, files, ctx)

            %Requirement{
              entity_type: "story",
              entity_id: story.id,
              entity_name: story.title,
              name: definition.name,
              description: definition.description,
              satisfied: result.satisfied,
              satisfied_by: definition.satisfied_by,
              scope: definition.scope || :local,
              execution_type: definition.execution_type || :main_agent,
              validation_type: definition.validation_type || :automatic,
              orchestrated_by: definition.orchestrated_by,
              render_command_always?: definition.render_command_always? || false,
              role: definition.role,
              parent_entity_id: project && project.id,
              parent_entity_name: project && project.name,
              prerequisites: [],
              details: Requirement.normalize_details(result.details)
            }
          end)

        edges = build_template_edges(template, id_map)
        {nodes, all_edges ++ edges}
      end)

    # Stash edges — they'll be merged into template_edges
    {nodes, edges}
  end

  defp compute_project_nodes(scope, ctx, config) do
    project = scope.active_project

    # Only the devops filter applies to the project template (see
    # compute_story_nodes) — devops: :off drops devops_setup so the graph
    # never demands infrastructure work.
    template = maybe_filter_devops(RequirementDefinitionData.project_graph(), config)
    files = ctx.files_by_project || []

    id_map = Map.new(template, fn d -> {d.id, [{"project", project.id, d.name}]} end)

    nodes =
      Enum.map(template, fn definition ->
        result = RequirementCalculator.compute_one(scope, project, definition, files, ctx)

        %Requirement{
          entity_type: "project",
          entity_id: project.id,
          entity_name: project.name,
          name: definition.name,
          description: definition.description,
          satisfied: result.satisfied,
          satisfied_by: definition.satisfied_by,
          scope: definition.scope || :local,
          execution_type: definition.execution_type || :main_agent,
          validation_type: definition.validation_type || :automatic,
          orchestrated_by: definition.orchestrated_by,
          render_command_always?: definition.render_command_always? || false,
          role: definition.role,
          prerequisites: [],
          details: Requirement.normalize_details(result.details)
        }
      end)

    edges = build_template_edges(template, id_map)
    {nodes, edges}
  end

  # -- Sorting --
  # Actionable nodes sorted by {tier, priority, rank} in three tiers:
  #
  #   0. Project requirements up to and including `qa_setup` — these gate
  #      everything below them. Working a component while the architecture
  #      is incoherent or incoming issues are untriaged means choosing that
  #      work from a stale picture.
  #   1. Story and component work, by story priority (components inherit
  #      their story's priority via `build_component_priority_map/1`).
  #      Untethered components rank last within the tier.
  #   2. The QA journey chain after `qa_setup` — end-game requirements that
  #      depend on the stories being done.
  #
  # Ties inside the project tiers break on requirement definition order.
  # Within a story's chain, graph edges already encode execution order
  # (e.g. bdd_specs_exist before implementation_file).
  #
  # This restores the tiering from 2d4f928b ("Fix priority: late project
  # requirements sort after story/component work"), which 3f7be0c9
  # ("Simplify actionable sorting to story priority only") collapsed into a
  # single dead-last project tier — burying architecture_designed and
  # issues_triaged beneath every tethered component requirement.
  # `issues_resolved` belongs here, with the journey it now gates.
  #
  # This set is hardcoded rather than derived from the edges, so moving a
  # requirement's dependencies moves what it *blocks* and leaves where it
  # *sorts* untouched. When `issues_resolved` stopped gating `qa_setup` and
  # started gating `qa_journey_plan`, it kept tier 0 — so it still rendered at
  # the front of the project band and was still offered ahead of every story and
  # component, which is the exact complaint that prompted moving it.
  #
  # Its prerequisite is still `issues_triaged`, and that is correct: you cannot
  # resolve what has not been triaged. Prerequisite position and sort tier are
  # different questions, and only the first is answered by the edges.
  @late_project_reqs MapSet.new([
                       "issues_resolved",
                       "qa_journey_plan",
                       "qa_journey_execute",
                       "qa_journey_wallaby"
                     ])

  defp sort_by_story_priority(nodes, ctx) do
    story_by_id = Map.new(ctx.stories, &{&1.id, &1})
    component_priority = build_component_priority_map(ctx)
    def_order = project_req_order()
    Enum.sort_by(nodes, &priority_sort_key(&1, story_by_id, component_priority, def_order))
  end

  # Requirement name → position in the project graph definition list.
  defp project_req_order do
    RequirementDefinitionData.project_graph()
    |> Enum.with_index()
    |> Map.new(fn {req, idx} -> {req.name, idx} end)
  end

  defp priority_sort_key(%{entity_type: "project", name: name}, _story_by_id, _comp, def_order) do
    tier = if MapSet.member?(@late_project_reqs, name), do: 2, else: 0
    {tier, 0, Map.get(def_order, name, 999)}
  end

  defp priority_sort_key(%{entity_type: "story", entity_id: id}, story_by_id, _comp, _def_order) do
    story = Map.get(story_by_id, id)
    {1, (story && story.priority) || 999, 0}
  end

  defp priority_sort_key(
         %{entity_type: "component", entity_id: id},
         _story,
         comp_priority,
         _order
       ) do
    case Map.fetch(comp_priority, id) do
      {:ok, priority} -> {1, priority, 0}
      :error -> {1, 999, 1}
    end
  end

  # Build a map of component_id → best (lowest) story priority.
  # A component inherits priority from:
  # 1. Stories that directly link to it (story.component_id)
  # 2. Stories that link to components that depend on it
  # 3. Parent components (via parent_component_id chain), recursively
  #    through any parent type. A bounded context's priority cascades
  #    to *every* descendant — direct children, grandchildren via
  #    behaviour/schema/module intermediates, the whole tree — so the
  #    descendants get worked together as one priority cohort. Trees
  #    rooted at a context with no priority (orphan contexts) yield
  #    no inheritance, and the untethered filter drops their
  #    descendants from the wave on that basis.
  defp build_component_priority_map(ctx) do
    # Direct: story.component_id → component
    direct =
      ctx.stories
      |> Enum.filter(& &1.component_id)
      |> Enum.reduce(%{}, fn story, acc ->
        priority = story.priority || 999
        Map.update(acc, story.component_id, priority, &min(&1, priority))
      end)

    # Spread priority to dependencies of surface components
    with_deps =
      ctx.stories
      |> Enum.filter(& &1.component_id)
      |> Enum.reduce(direct, fn story, acc ->
        surface = Map.get(ctx.components_by_id, story.component_id)
        priority = story.priority || 999

        deps =
          case surface && surface.dependencies do
            %Ecto.Association.NotLoaded{} -> []
            deps when is_list(deps) -> deps
            _ -> []
          end

        Enum.reduce(deps, acc, fn dep, inner_acc ->
          Map.update(inner_acc, dep.id, priority, &min(&1, priority))
        end)
      end)

    # Spread priority down parent_component_id chains, unconditional —
    # the chain stops only when a parent has no priority of its own.
    parent_map = Map.new(ctx.components, &{&1.id, &1.parent_component_id})

    Enum.reduce(ctx.components, with_deps, fn comp, acc ->
      if Map.has_key?(acc, comp.id) do
        acc
      else
        # Walk up parent chain looking for a component with priority
        find_priority_from_parent(comp.id, parent_map, acc)
      end
    end)
  end

  defp find_priority_from_parent(nil, _parent_map, acc), do: acc

  defp find_priority_from_parent(component_id, parent_map, acc) do
    if Map.has_key?(acc, component_id),
      do: acc,
      else: walk_to_parent(component_id, parent_map, acc)
  end

  defp walk_to_parent(component_id, parent_map, acc) do
    case Map.get(parent_map, component_id) do
      nil -> acc
      parent_id -> inherit_priority(component_id, parent_id, parent_map, acc)
    end
  end

  defp inherit_priority(component_id, parent_id, parent_map, acc) do
    acc = find_priority_from_parent(parent_id, parent_map, acc)

    case Map.get(acc, parent_id) do
      nil -> acc
      priority -> Map.put(acc, component_id, priority)
    end
  end

  # -- Configuration-based filtering --

  # Filters component requirement definitions based on ProjectConfiguration.
  # require_specs: false → removes :specification artifact types
  # require_reviews: false → removes :review artifact types
  # require_unit_tests: false → removes :tests artifact type + tests_passing
  #
  # The graph is now silent about infrastructure for every project, not just
  # `devops: :off` ones — see `maybe_filter_devops/2`.
  defp filter_definitions_by_config(definitions, config) do
    definitions
    |> maybe_filter_specs(config)
    |> maybe_filter_reviews(config)
    |> maybe_filter_tests(config)
    |> maybe_filter_devops(config)
  end

  # `deploy` is back, reading `CodeMySpec.Deploys` rather than a markdown file
  # the agent wrote for itself — which is why it came out (d207ad38) and what
  # had to change before it could return.
  #
  # `devops: :off` is the default, so for most projects this filter is what
  # keeps the graph silent about infrastructure (criterion 1970). Absent, not
  # present-and-skipped: a greyed-out step still reads as part of the run.
  #
  # `devops_setup` and `release` remain out. Setup is answered by
  # `devops_status` against the providers, and release has no read model yet.
  defp maybe_filter_devops(definitions, %{devops: :off}) do
    Enum.reject(definitions, &(&1.artifact_type == :deployment))
  end

  defp maybe_filter_devops(definitions, _config), do: definitions

  defp maybe_filter_specs(definitions, %{require_specs: false}) do
    Enum.reject(definitions, &(&1.artifact_type == :specification))
  end

  defp maybe_filter_specs(definitions, _config), do: definitions

  defp maybe_filter_reviews(definitions, %{require_reviews: false}) do
    Enum.reject(definitions, &(&1.artifact_type == :review))
  end

  defp maybe_filter_reviews(definitions, _config), do: definitions

  defp maybe_filter_tests(definitions, %{require_unit_tests: false}) do
    Enum.reject(definitions, fn def ->
      def.artifact_type == :tests or def.name == "tests_passing"
    end)
  end

  defp maybe_filter_tests(definitions, _config), do: definitions
end
