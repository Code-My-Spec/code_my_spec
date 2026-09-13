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

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Difference
  alias CodeMySpec.Requirements.Freshness
  alias CodeMySpec.Requirements.GraphCache
  alias CodeMySpec.Requirements.GraphFingerprint
  alias CodeMySpec.Requirements.NodeRepository
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
    scope = normalize_vantage(scope)
    {preload_us, loaded} = :timer.tc(fn -> Preloader.load(scope) end)

    with {:ok, ctx} <- loaded do
      config = CodeMySpec.Configurations.get_or_create(scope)
      compute_and_publish(scope, ctx, config, preload_us)
    end
  end

  # The whole read-and-write path for one computation — `Preloader`, `GraphCache`
  # and `NodeRepository`/`Projection` — has to agree on one `working_copy_id`, or
  # a UI publish computes from one identity and stores under another (276c2afe):
  # `Preloader.load/1` and `GraphCache` both decide "whose view is this" from the
  # raw `active_working_copy_id` field, while `NodeRepository.upsert_all/2` and
  # `Projection.load/2` decide it from `Projection.vantage/1`, which resolves a
  # caller with no checkout to name to the project's default working copy once
  # one is set. The two coincide until a project gets a default, then a UI
  # publish blends every checkout's files (`Preloader`, raw nil), caches under
  # its own row (`GraphCache`, raw nil), and persists under the default
  # checkout's identity (`NodeRepository`, resolved) — overwriting that
  # checkout's own accurately-scoped rows with the blended, over-satisfying
  # verdict.
  #
  # Resolving `vantage/1` once, here, before `Preloader.load/1` ever sees the
  # scope, is what the docs on both `vantage/1` and `Preloader.load/1` already
  # argued for ("a web view should read the default branch ... At that point
  # the question 'which harness is the UI showing' stops existing"). Every
  # downstream call still reads the same raw field it always did; only the
  # value it finds there is now the resolved one, so nothing else changes.
  defp normalize_vantage(%Scope{} = scope),
    do: %{scope | active_working_copy_id: Projection.vantage(scope)}

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
  # A miss does not mean everything moved.
  #
  # The project fingerprint is one hash over every input, so a scenario added to
  # one story busts it exactly as hard as a component being deleted, and the
  # only response available was to rebuild all of it. Measured here: 348 full
  # computes in one log, median 2.6s, p90 5.9s, max 14.8s, 116 of them from stop
  # hooks, with edges 6489ms of a 10203ms compute.
  #
  # `FileSync` now clears `inputs_fingerprint` on the requirements a changed
  # path bears on, so the rows say which of them need an answer. This keeps the
  # rest and computes only those. Criterion 3424.
  #
  # ## Project nodes are always recomputed, and that is not an oversight
  #
  # They read counts — whether any story exists, how many components are
  # designed — so they depend on the whole context rather than on one entity's
  # slice. Computing them from a reduced context would answer "how many stories
  # are there" with the number of stale ones. There are fourteen of them and
  # they are cheap; the expense is the other two thousand.
  #
  # ## The edges are the saving, and the thing most easily got wrong
  #
  # Edges are kept wholesale, which is where the time actually goes — 6489ms of
  # a 10203ms compute, against 3714ms for every node in the project. Keeping
  # them is only sound while the shape they describe has not moved, and the
  # entity set does not answer that: `cross_context_dependency_edges/2` reads
  # `component.dependencies`, so a spec file declaring a new dependency moves
  # the graph's shape without adding or removing a single entity. That
  # component would be recomputed correctly and its new edge dropped silently.
  #
  # `Freshness.topology/2` is the question asked instead — dependencies, the
  # component tree, story attachment and the config filters, and nothing else.
  # It is compared against what the stored edges were published from, so reuse
  # rests on the shape being unchanged rather than on membership being
  # unchanged.
  #
  # ## Conservative wherever reuse would rest on something unproven
  #
  # Falls back to the whole computation when there are no stored rows to keep,
  # when the entity set has moved, or when the topology has — each of them a
  # different question from whether an answer is current. A graph that is
  # slower than it needs to be costs time; a graph that is wrong is an agent
  # doing work that does not exist.
  @doc """
  Apply analysis freshness to computed or stored requirements, on the way out.

  The half of a `:tests_passing` verdict that is not durable. The row holds the
  component's own problem count; whether the run behind that count still
  describes the current code is a project-wide fact that changes on its own
  schedule, and baking it into rows made an analyzer finishing recompute 1116 of
  1347 requirements to correct one term. Criterion 3448.

  **Downgrades only.** A stored `false` is never turned into a pass, so this
  cannot manufacture the false positive the asymmetry exists to prevent — it can
  only withhold a clean verdict whose evidence has gone stale. That also makes
  it idempotent, which is why applying it on both the cached and the computed
  path is safe.

  Keyed off `details.analysis_source`, written by `problem_verdict/5`, so a
  requirement says for itself which analyzer it leans on rather than this
  needing a table of names.
  """
  @spec serve([Requirement.t()], Preloader.context()) :: [Requirement.t()]
  def serve(nodes, ctx) do
    fresh = Map.get(ctx, :analysis_fresh, %{})
    Enum.map(nodes, &apply_freshness(&1, fresh))
  end

  defp apply_freshness(node, fresh) do
    case analysis_source(node) do
      source when is_binary(source) -> freshen(node, source, Map.get(fresh, source, false))
      nil -> node
    end
  end

  defp freshen(node, _source, true), do: node
  defp freshen(node, source, false), do: stale(node, source)

  # Both directions of the asymmetry, applied at serve time rather than baked
  # into the row. `StaleAnalysisTest` is what this has to keep true, and it was
  # bought by a drill: an agent re-fixed four credo findings it had already
  # corrected, because a stale list is indistinguishable from a current one when
  # nothing says so.
  #
  # A stale **zero** refuses. Clean from a run that never saw this code is a
  # false pass, and that is the direction that costs correctness.
  #
  # A stale **count** is still served, with its vintage named. Withholding it
  # instead left any source slower than the edit cadence permanently "pending",
  # never answering at all (issue 7a7eed33) — absent information rendered as a
  # blocked requirement.
  defp stale(%{satisfied: true} = node, source) do
    %{
      node
      | satisfied: false,
        details:
          node.details
          |> put_detail(
            :reason,
            "#{source} results not current — the last completed run " <>
              "predates your changes, so a clean result from it proves nothing"
          )
          |> put_detail(:stale, true)
    }
  end

  defp stale(node, source) do
    case read_detail(node.details, :reason) do
      reason when is_binary(reason) and reason != "" ->
        %{
          node
          | details:
              node.details
              |> put_detail(:reason, "#{reason}, from the last completed #{source} run")
              |> put_detail(:stale, true)
        }

      _ ->
        %{node | details: put_detail(node.details, :stale, true)}
    end
  end

  # Written back in the key style the map already uses.
  #
  # `problem_verdict/5` builds atom-keyed details and a rehydrated row carries
  # string-keyed ones, and both reach here. Normalising to strings on the way
  # out broke `details.reason` for every caller holding a freshly computed
  # requirement — `StaleAnalysisTest` caught it — so the overlay preserves
  # whichever style it was handed rather than imposing one.
  defp put_detail(details, key, value) when is_map(details) do
    if atom_keyed?(details),
      do: Map.put(details, key, value),
      else: Map.put(details, to_string(key), value)
  end

  defp put_detail(_details, key, value), do: %{key => value}

  defp read_detail(details, key) when is_map(details),
    do: Map.get(details, key) || Map.get(details, to_string(key))

  defp read_detail(_details, _key), do: nil

  defp atom_keyed?(details) do
    case Map.keys(details) do
      [] -> true
      keys -> Enum.any?(keys, &is_atom/1)
    end
  end

  defp analysis_source(%{details: details}) when is_map(details) do
    case Requirement.normalize_details(details) do
      %{"analysis_source" => source} when is_binary(source) -> source
      _ -> nil
    end
  end

  defp analysis_source(_node), do: nil

  defp recompute_stale(scope, ctx, config) do
    stamp_project(scope)
    {stored_nodes, stored_edges} = Projection.load(scope, ctx)

    topology = Freshness.topology(ctx, config)

    with {_, true} <- {:no_stored_rows, stored_nodes != []},
         {_, true} <- {:topology_moved, topology == GraphCache.topology_fingerprint(scope)},
         {_, {:partial, stale}} <-
           {:everything_stale, stale_entities(stored_nodes, ctx)} do
      reduced = reduce_to(ctx, stale)

      {component_nodes, _} = instantiate_component_graphs(scope, reduced, config)
      {story_nodes, _} = compute_story_nodes(scope, reduced, config)
      {project_nodes, _} = compute_project_nodes(scope, ctx, config)

      fresh = project_nodes ++ story_nodes ++ component_nodes

      # Departed as well as stale: a row for an entity the context no longer has
      # is not refreshed by this pass and must not be carried into the served
      # graph on the strength of having been true once.
      gone = departed(stored_nodes, ctx)

      kept =
        Enum.reject(
          stored_nodes,
          &(entity_key(&1) in stale or entity_key(&1) in gone or &1.entity_type == "project")
        )

      nodes = kept ++ fresh

      # Split by kind, and with the two project-wide inputs beside it, because
      # "665 entities stale" does not say whether that was 665 real changes or
      # one shared input taking everybody with it. Stories and components have
      # different shared inputs — `analysis_fresh` for components, the running
      # copy for stories — so the split alone distinguishes them: all components
      # and no stories is the analyser flipping, all stories and no components
      # is the running copy moving, and a partial count of each is genuine file
      # change. Guessing between those three cost most of a day.
      {stale_stories, stale_comps} =
        Enum.split_with(stale, fn {type, _id} -> type == "story" end)

      Logger.info(
        "[Requirements] recomputed #{length(fresh)} of #{length(nodes)} requirements — " <>
          "#{MapSet.size(stale)} entity(ies) stale " <>
          "(#{length(stale_stories)}/#{length(ctx.stories)} stories, " <>
          "#{length(stale_comps)}/#{length(ctx.components)} components); " <>
          "analysis_fresh=#{inspect(Map.get(ctx, :analysis_fresh, %{}))}"
      )

      # `reduced`, not `ctx`, and this is the whole reason the first attempt
      # reused nothing. `persist_projection/5` hands `visited/1` to
      # `delete_departed/4`, which reaps every row belonging to a visited entity
      # that this write did not produce — so visiting the full context while
      # writing only the stale rows deletes precisely the rows being kept. The
      # next read then finds a shortfall and recomputes everything, which is the
      # behaviour this function exists to remove, arriving as a reap.
      scope
      |> GraphCache.publish(
        GraphFingerprint.compute(ctx, config),
        {nodes, stored_edges},
        topology
      )
      |> persist_projection(scope, reduced, fresh, stored_edges, {ctx, nodes})

      {serve(nodes, ctx), stored_edges}
    else
      # Which guard sent it to the whole computation, because without this the
      # only observable difference between "reuse is working" and "reuse never
      # fires" is a log line that does not appear — and on this project it did
      # not appear once. Reuse is the point of the function; a fallback nobody
      # can see the reason for is the function quietly not doing it.
      {:topology_moved, _} ->
        # Which of the three, because "the shape moved" is as unanswerable as
        # "the entity set moved" was, and that one turned out to be a guard that
        # could never hold. Printed as the parts themselves so two consecutive
        # lines name the mover by the digest that differs between them.
        # Flat and short, because a logfmt value is truncated at 500 bytes and an
        # `inspect/1` of a map wraps: the first attempt logged `%{config:` and
        # nothing else, which is a diagnostic that reports only that it ran.
        parts =
          ctx
          |> Freshness.topology_parts(config)
          |> Enum.sort()
          |> Enum.map_join(" ", fn {part, digest} ->
            "#{part}=#{binary_part(digest, 0, 8)}"
          end)

        Logger.info("[Requirements] full recompute — topology_moved #{parts}")

        compute_and_publish(scope, ctx, config)

      # The counts that decided it, for the same reason `topology_moved` prints
      # its parts one clause up: `everything_stale` on its own says a full
      # recompute happened and nothing about why, and "why" here is a
      # comparison between two numbers that are not otherwise recoverable.
      #
      # Cost of not having them: three wrong hypotheses in one sitting, each
      # plausible and each taking a database query to rule out — entities that
      # never produce rows counting as new forever, a component family
      # expanding to the whole project, a vantage small enough that an ordinary
      # stale set clears its bar. The line below distinguishes all three, and
      # the last one is not a fault at all: a copy holding twenty entities has
      # nothing to reuse, and recomputing it whole is both correct and cheap.
      {:everything_stale, {:all, why}} ->
        Logger.info("[Requirements] full recompute — everything_stale #{why}")
        compute_and_publish(scope, ctx, config)

      {why, _} ->
        Logger.info("[Requirements] full recompute — #{why}")
        compute_and_publish(scope, ctx, config)
    end
  end

  # Whose graph this is, on every line the read emits.
  #
  # These lines carried `ts`, `level`, `src`, `inst` and `mfa` and no project,
  # so a count of full computes or analyzer-driven recomputes was a count across
  # every project this server handles — `broken_oaths`, `math_test_project` and
  # the qa sandboxes among them. I reported "no full computes since the backfill"
  # from exactly that measurement, and only caught it because the topology
  # digest happens to include the config, which is per project and gave three
  # of them away as somebody else's.
  #
  # `cms_project`, matching the `cms_session` / `cms_hook` convention the stop
  # hook already uses. Process metadata, so every subsequent line in the same
  # read inherits it.
  defp stamp_project(%Scope{active_project_id: project_id}) when is_binary(project_id),
    do: Logger.metadata(cms_project: project_id)

  defp stamp_project(_scope), do: :ok

  # Which entities' answers no longer match what their inputs say now.
  #
  # ## Asked of the inputs, not of a flag
  #
  # The first version read staleness only as `inputs_fingerprint IS NULL` —
  # cleared by a writer that knew it had changed something. That covers exactly
  # the writers that remembered to say so, which was `FileSync` and nothing
  # else: a scenario added to a story is a row in `criteria`, not a file, so
  # nothing cleared anything and the story's requirements were kept as fresh
  # while the observation that moved them had already landed. Criterion 3424
  # caught it — both readings carried the same stamp because *neither* story
  # was recomputed.
  #
  # A stale answer is worse than a slow one: it is an agent handed work the
  # observation has already done, or told a thing is done that is not. So the
  # question is asked of the sources directly. The context is loaded by then —
  # every input is in hand — and hashing it per entity is cheap beside
  # computing the requirements it would otherwise skip.
  #
  # Clearing the column stays meaningful and stays wired: `nil` matches no
  # fingerprint, so a writer that knows it invalidated something still forces
  # the recompute, across every checkout, without having to work out what the
  # new value would be.
  #
  # `:all` when every entity is stale — reusing nothing is the whole
  # computation, and the simpler path is the honest way to spend it.
  defp stale_entities(stored_nodes, ctx) do
    current = current_fingerprints(ctx)

    recorded =
      stored_nodes
      |> Enum.reject(&(&1.entity_type == "project"))
      |> Enum.group_by(&entity_key/1, & &1.inputs_fingerprint)

    stale =
      recorded
      |> Enum.reject(fn {key, fingerprints} ->
        # Every requirement of an entity is stamped with the same value, so
        # agreement is `[fingerprint]` and anything else — a `nil`, a mix left
        # by a half-written earlier pass — is a reason to recompute.
        Enum.uniq(fingerprints) == [Map.get(current, key)]
      end)
      |> MapSet.new(fn {key, _} -> key end)
      |> expand_component_families(ctx)

    # An entity the context has and the rows do not is stale by definition:
    # nothing has ever computed it. Most of them will produce no nodes — a
    # child component whose parent template has no `:child` definitions never
    # does — and computing them costs nothing and settles it either way.
    appeared =
      MapSet.union(
        MapSet.new(ctx.components, &{"component", &1.id}),
        MapSet.new(ctx.stories, &{"story", &1.id})
      )
      |> MapSet.reject(&Map.has_key?(recorded, &1))

    moved = stale
    stale = MapSet.union(stale, appeared)
    entities = MapSet.new(Map.keys(recorded))

    verdict(stale, entities, moved, appeared, ctx)
  end

  # `{:partial, set}` or `{:all, why}`, rather than a set or the bare atom the
  # guard used to compare against. The reason travels with the verdict because
  # the caller logs it and cannot reconstruct it: by then `recorded` and
  # `appeared` are out of scope, and the two numbers being compared are the
  # whole of the decision.
  defp verdict(stale, entities, moved, appeared, ctx) do
    all? = MapSet.size(stale) >= MapSet.size(entities) and MapSet.size(entities) > 0

    case all? do
      false -> {:partial, stale}
      true -> {:all, why_all(stale, entities, moved, appeared, ctx)}
    end
  end

  # Flat and short: a logfmt value is truncated at 500 bytes, and the `%{...}`
  # of an inspected map wraps — `topology_moved` learned that the expensive way.
  #
  # `appeared` separated from `moved` because they are different faults with
  # different fixes. `appeared` is an entity the rows have never held, and a
  # population of those that never shrinks is a guard that can never pass —
  # which is exactly how `entity_set_moved` died. `moved` is fingerprints
  # genuinely differing, which is the honest reason to recompute.
  defp why_all(stale, entities, moved, appeared, ctx) do
    "stale=#{MapSet.size(stale)} >= recorded=#{MapSet.size(entities)} " <>
      "(moved=#{MapSet.size(moved)} appeared=#{MapSet.size(appeared)}) " <>
      "ctx=#{length(ctx.components)}c/#{length(ctx.stories)}s"
  end

  # What each entity's inputs say right now.
  #
  # Computed from the same by-id maps the requirements themselves read, and
  # `reduce_to/2` narrows only the two lists, so an entity hashes identically
  # whether the pass that stamped it was partial or whole. That has to hold:
  # a stamp written during a partial recompute is compared against one computed
  # from a full context on the next read, and if the two disagreed every row
  # would look stale forever and this would be the old behaviour with extra
  # hashing.
  defp current_fingerprints(ctx) do
    stories = Map.new(ctx.stories, &{{"story", &1.id}, Freshness.story(ctx, &1)})
    components = Map.new(ctx.components, &{{"component", &1.id}, Freshness.component(ctx, &1)})

    Map.merge(stories, components)
  end

  # A component and its parent recompute together, or not at all.
  #
  # `instantiate_component_graphs/3` runs one template per *family*: a
  # container's pass instantiates its children's nodes too, and a component
  # whose parent is absent from the list is treated as top-level and runs a
  # different template. So narrowing the context to a stale child alone would
  # not recompute that child — it would compute a different component.
  #
  # One level, matching the grouping that function actually does. Grouping a
  # child under a parent that turns out not to be a container recomputes both
  # where one would have done, which costs a little and cannot be wrong.
  defp expand_component_families(stale, ctx) do
    ctx.components
    |> Enum.group_by(&(&1.parent_component_id || &1.id), & &1.id)
    |> Enum.reduce(stale, fn {_family, ids}, acc ->
      if Enum.any?(ids, &MapSet.member?(acc, {"component", &1})),
        do: Enum.reduce(ids, acc, &MapSet.put(&2, {"component", &1})),
        else: acc
    end)
  end

  # Rows whose entity is no longer in the context at all.
  #
  # Replaces an equality check between the stored entity set and the context's,
  # which could not hold on any project with a nested component. `stored` is
  # drawn from stored *nodes*, and a child component emits nodes only when its
  # parent's template has `:child`-scope definitions for it — so 52 of this
  # project's 1121 components produce none, are absent from `stored` by
  # construction, and made the sets unequal on every read forever. Measured: ten
  # consecutive reads, every one of them `entity_set_moved`, never a partial
  # recompute.
  #
  # What that check was really protecting is whether the stored edges still
  # describe this graph, and `Freshness.topology/2` answers that directly. This
  # answers the other half: a row for an entity the context no longer has must
  # not survive into the served graph.
  defp departed(stored_nodes, ctx) do
    current =
      MapSet.union(
        MapSet.new(ctx.components, &{"component", &1.id}),
        MapSet.new(ctx.stories, &{"story", &1.id})
      )

    stored_nodes
    |> Enum.reject(&(&1.entity_type == "project"))
    |> MapSet.new(&entity_key/1)
    |> MapSet.reject(&MapSet.member?(current, &1))
  end

  defp entity_key(node), do: {node.entity_type, node.entity_id}

  # Only the lists are narrowed. The by-id maps stay whole because the
  # computation reads them by the entity it is working on, and rebuilding them
  # would cost more than the lookup saves.
  defp reduce_to(ctx, stale) do
    %{
      ctx
      | components: Enum.filter(ctx.components, &MapSet.member?(stale, {"component", &1.id})),
        stories: Enum.filter(ctx.stories, &MapSet.member?(stale, {"story", &1.id}))
    }
  end

  defp compute_and_publish(scope, ctx, config, preload_us \\ nil) do
    stamp_project(scope)

    {nodes_us, {nodes, enriched_ctx}} =
      :timer.tc(fn -> compute_all_from_ctx(scope, ctx, config) end)

    {edges_us, edges} = :timer.tc(fn -> compute_edges(nodes, enriched_ctx, config) end)

    log_timing(scope, preload_us, nodes_us, edges_us, nodes, edges)

    # The topology goes down with the edges it describes. Recorded here and
    # nowhere else: this is the only path that computes edges, so it is the only
    # path entitled to say what shape they came from.
    scope
    |> GraphCache.publish(
      GraphFingerprint.compute(ctx, config),
      {nodes, edges},
      Freshness.topology(ctx, config)
    )
    |> persist_projection(scope, enriched_ctx, nodes, edges)

    # Persisted durable, returned overlaid — in that order. The rows must hold
    # the component's own answer so a freshness flip does not invalidate them;
    # the caller must see the qualified one so it never acts on a clean verdict
    # whose run has gone stale.
    {serve(nodes, ctx), edges}
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

  # A cache hit means the rows are current, so a hit is served from the rows.
  #
  # `requirement_graphs` used to carry a `payload` — the whole graph as an
  # Erlang term — and this compared the two and served the rows unless there
  # were none. That was the retirement plan working: serve the projection,
  # compare it against the payload on every publish, and keep the payload only
  # to cover a graph whose rows were never written.
  #
  # All three conditions the plan named are met. The round-trip check has run on
  # every publish since — 828 computations across four rotated logs — and
  # `the projection does not round-trip` has never appeared, nor has
  # `projection is empty for a payload`. So the rows are the graph, and the
  # payload was a second copy of them that could disagree.
  #
  # What is kept from it is the one thing rows cannot say about themselves:
  # `node_count`, recorded by the publish that wrote them. Rows that are empty
  # where the publish counted nodes are rows that were never written, and that
  # is a miss — recompute — rather than an empty graph served as current. An
  # empty graph tells an agent it has no work, which is the wrong answer to give
  # for a write that failed.
  #
  # Short counts are the same failure, and were served as current until QA found
  # them. `Projection.load/2` rebuilds each row against the preloaded context and
  # drops whatever it cannot — `rehydrate/2` answers nil when `entity_for/2`
  # cannot place the row's entity or `definition_for/2` cannot find its
  # definition — so a hit could return a strict subset of what the publish
  # counted, with nothing amiss in either the write or the read.
  #
  # Measured on story 1062: 2009 nodes computed, 1844 served from cache, stable
  # across reads, back to 2009 on the next recompute, all under one `computed_at`
  # (7a6b92e3). Two graphs wearing one timestamp, which is precisely what
  # criterion 3246 says must not happen and what criterion 3358 now states
  # directly.
  #
  # Refusing the short read rather than repairing the projection, deliberately.
  # The count is the publish's own claim about itself and is therefore the one
  # number a read cannot argue with; whatever makes rehydration fail is worth
  # finding, but until it is found a recompute is a correct answer and a subset
  # is not. The cost is a recompute on a project that reproduces it, which is
  # loud in the log and better than quiet wrong numbers.
  defp served_graph(scope, ctx, published_nodes) do
    case Projection.load(scope, ctx) do
      {[], _} when published_nodes > 0 ->
        Logger.warning(
          "[Requirements] no requirement rows for a graph published with " <>
            "#{published_nodes} nodes — recomputing. The row write for it did not land."
        )

        :no_rows

      {nodes, _edges} when length(nodes) < published_nodes ->
        Logger.warning(
          "[Requirements] a graph published with #{published_nodes} nodes reads back as " <>
            "#{length(nodes)} — recomputing. `Projection.load/2` rebuilds each row against " <>
            "the preloaded context and drops what it cannot, so the shortfall is rows the " <>
            "publish counted and this read could not reconstitute."
        )

        :no_rows

      {nodes, edges} ->
        # The cached path's overlay. `compute_and_publish/4` and
        # `recompute_stale/3` each apply it to what they return; this is the
        # third way nodes reach a reader, and criterion 3358 requires a cached
        # answer and a fresh one to describe the same graph — which they would
        # not if freshness were applied on one path and not the other.
        {:ok, {serve(nodes, ctx), edges}}
    end
  end

  # Written behind the same fingerprint check that gates the cache row. Readers
  # reach here on every render, so an unconditional upsert of every node per
  # page view is exactly what `publish/3` already refuses to do for one row.
  defp persist_projection(publish, scope, ctx, nodes, edges, verify \\ nil)

  defp persist_projection(:unchanged, _scope, _ctx, _nodes, _edges, _verify), do: :ok

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
  defp persist_projection(:published, scope, ctx, nodes, edges, verify) do
    {:ok, _} =
      Repo.transaction(fn ->
        ids_by_key = NodeRepository.upsert_all(scope, nodes, visited(ctx))
        NodeRepository.replace_edges(scope, edges, ids_by_key)
      end)

    # Outside the transaction on purpose. Verification is a check *about* the
    # write, not part of it — running it inside would let a failed check roll
    # back rows that are correct, which is the opposite of what it is for.
    #
    # `verify` carries the *whole* graph when the write was a partial one. A
    # partial write is given the reduced context and the fresh nodes, which is
    # right for writing — `visited/1` must not reap the rows being kept — and
    # wrong for checking, because `Projection.load/2` rehydrates against the
    # context it is handed and so reads back only the stale entities' rows.
    # Comparing that against a full payload reports thousands of edges missing
    # that were never read.
    #
    # It did: 70 warnings from the first partial recompute onward, on a check
    # whose own comment recorded that it had never fired in 828 computations.
    # Nothing was actually lost — `replace_edges/3` deletes only among the node
    # ids it is given, so edges touching kept nodes are left alone — but a
    # warning that cries wolf 70 times is worse than no warning at all, because
    # the next real one is invisible.
    case verify do
      {verify_ctx, verify_nodes} -> verify_round_trip(scope, verify_ctx, verify_nodes, edges)
      nil -> verify_round_trip(scope, ctx, nodes, edges)
    end

    :ok
  end

  # What this computation looked at, which is the preloaded context rather than
  # the nodes it produced. A component whose template is empty under this
  # project's configuration produces nothing and was still visited; its old rows
  # are departed and must be reaped. See `NodeRepository.delete_departed/4`.
  defp visited(ctx) do
    %{
      components: Enum.map(ctx.components, & &1.id),
      stories: Enum.map(ctx.stories, & &1.id)
    }
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
    scope = normalize_vantage(scope)

    with {:ok, ctx} <- Preloader.load(scope) do
      cached_graph_with_actionable(scope, ctx)
    end
  end

  @doc """
  The same, with what a reader needs to say where the answer came from.

  For the requirements graph page, which used
  `compute_graph_with_actionable_metrics/1` — the full recompute, 4.4 seconds on
  a 3200-component project, on every visit. So the most-looked-at reader of the
  graph was the one reader that never used the cache, while two stories were
  written to make the cached answer trustworthy.

  It also had nothing to show about freshness, because it had no cached answer
  to be fresh or stale. QA on story 1063 went looking for `computed_at` on that
  page and found it discarded; there was nothing to discard.

  `served_from` is `"cache"` when a published graph satisfied the fingerprint
  and `"computed"` when this call produced it. On a miss `computed_at` is
  stamped now rather than left nil — the answer *was* computed at that moment,
  and nil reads as "no answer" while meaning the opposite.
  """
  @spec cached_graph_with_actionable_metrics(Scope.t()) ::
          {{[Requirement.t()], [edge()], [Requirement.t()]}, map()}
  def cached_graph_with_actionable_metrics(%Scope{} = scope) do
    scope = normalize_vantage(scope)
    {us_preload, {:ok, ctx}} = :timer.tc(fn -> Preloader.load(scope) end)

    {us_graph, {{nodes, edges}, actionable, computed_at}} =
      :timer.tc(fn -> cached_graph_with_actionable(scope, ctx) end)

    metrics = %{
      preload_ms: div(us_preload, 1000),
      graph_ms: div(us_graph, 1000),
      node_count: length(nodes),
      edge_count: length(edges),
      computed_at: computed_at || published_at(scope, ctx),
      served_from: if(computed_at, do: "cache", else: "computed")
    }

    {{nodes, edges, actionable}, metrics}
  end

  # The timestamp the compute actually stored, not the moment we got round to
  # displaying it.
  #
  # `cached_graph_with_actionable/2` answers `nil` on a miss — its contract is
  # "this read computed the answer", and `cached_all/1` depends on that nil
  # meaning exactly that, so it stays. But a page needs something to show, and
  # stamping `DateTime.utc_now()` here showed a time the answer was not computed
  # at: QA measured the gap at 49ms and 185ms on two runs, because the publish
  # happens before `actionable_from/3` and the round-trip check finish.
  #
  # Small, and wrong in the way that matters for this surface. The whole point
  # of the strip is to let someone compare `computed_at` across reads, and a
  # fresh compute that reports a different instant from the cached read of the
  # same computation makes that comparison lie about which is newer.
  #
  # One indexed read, immediately after a compute that cost seconds.
  defp published_at(scope, ctx) do
    case GraphCache.fetch(scope, GraphFingerprint.compute(ctx, config_for(scope))) do
      {:ok, _nodes, at} -> at
      :miss -> DateTime.utc_now()
    end
  end

  defp config_for(scope), do: CodeMySpec.Configurations.get_or_create(scope)

  defp cached_graph_with_actionable(scope, ctx) do
    config = CodeMySpec.Configurations.get_or_create(scope)

    {graph, computed_at} =
      case GraphCache.fetch(scope, GraphFingerprint.compute(ctx, config)) do
        {:ok, published_nodes, at} ->
          case served_graph(scope, ctx, published_nodes) do
            {:ok, graph} -> {graph, at}
            :no_rows -> {compute_and_publish(scope, ctx, config), nil}
          end

        :miss ->
          {recompute_stale(scope, ctx, config), nil}
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
    scope = normalize_vantage(scope)
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
    scope = normalize_vantage(scope)

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
    |> stamp_component_freshness(ctx)
  end

  # Stamped after the fact rather than inside the template, because a
  # container's pass emits its children's nodes as well as its own and each of
  # them is stale on its own inputs. Keyed off `entity_id`, so a child node
  # carries the child's fingerprint wherever it was produced.
  defp stamp_component_freshness({nodes, edges}, ctx) do
    fingerprints = Map.new(ctx.components, &{&1.id, Freshness.component(ctx, &1)})

    nodes =
      Enum.map(nodes, fn
        %{entity_type: "component", entity_id: id} = node ->
          %{node | inputs_fingerprint: Map.get(fingerprints, id)}

        node ->
          node
      end)

    {nodes, edges}
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

        # Stamped once per story rather than once per requirement: every
        # requirement of a story reads the same slice of the context, so they
        # go stale together and hashing it seven times would answer the same
        # question seven ways.
        fingerprint = Freshness.story(ctx, story)

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
              details: Requirement.normalize_details(result.details),
              inputs_fingerprint: fingerprint
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

  # Requirement name → its position along the story chain, longest-prerequisite
  # path first. Derived from the same template the graph is built from, so
  # adding a node to `story_graph/0` orders it without a second edit here.
  defp story_req_depth(name) do
    Map.get(story_req_order(), name, 999)
  end

  defp story_req_order do
    defs = RequirementDefinitionData.story_requirements()
    by_id = Map.new(defs, &{&1.id, &1})

    defs
    |> Enum.map(&{&1.name, chain_depth(&1, by_id, MapSet.new())})
    |> Map.new()
  end

  # Depth is the longest prerequisite chain behind a node. `bdd_specs_passing`
  # sits deeper than `bdd_specs_exist`, so finishing beats starting.
  # The visited set guards a template that ever gains a cycle; without it a bad
  # edit would hang the sort rather than mis-order it.
  defp chain_depth(%{id: id, prerequisites: prereqs}, by_id, visited) do
    if MapSet.member?(visited, id) do
      0
    else
      visited = MapSet.put(visited, id)
      prereqs |> Enum.map(&prereq_depth(&1, by_id, visited)) |> Enum.max(fn -> 0 end)
    end
  end

  defp prereq_depth(prereq_id, by_id, visited) do
    case Map.fetch(by_id, prereq_id) do
      {:ok, prereq} -> 1 + chain_depth(prereq, by_id, visited)
      :error -> 0
    end
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

  # The third term is how far down its own chain the node sits, so a story
  # already under way outranks a story nobody has started at the same priority.
  #
  # It was a hard-coded `0`, which made every story requirement identical to
  # the sort except for the story's priority — and 32 of Broken Oaths' 61
  # stories carry no priority at all, so they collapsed into one tie group
  # resolved by whatever order the graph builder emitted. With three coding
  # agents on one working copy each taking the next unclaimed node, that is
  # three stories in flight and none of them finished: specs written across ten
  # stories, code for none of them. The preferred motion is one story at a time
  # — specs, then code, then QA — and the sort is where that gets said.
  defp priority_sort_key(
         %{entity_type: "story", entity_id: id, name: name},
         story_by_id,
         _comp,
         _def_order
       ) do
    story = Map.get(story_by_id, id)
    {1, (story && story.priority) || 999, story_req_depth(name)}
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

  # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
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
