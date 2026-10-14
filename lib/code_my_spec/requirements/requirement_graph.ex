defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph — nodes AND edges — from Files and the project's records.

  The graph is entity-agnostic: edges represent real dependencies regardless of
  whether they cross entity boundaries. There are three kinds of edges:

  1. **Same-entity prerequisites**: ordered story and project requirements
  2. **Project → story**: project.qa_setup → story.component_linked (the
     whole-project gate that opens story-level work)
  2. **Story → component tree**: bdd_specs_exist → component's first req;
     component's terminal req → ready_for_qa → qa_complete
  3. **Stories → project**: each story's qa_complete → qa_journey_plan
     (project-level fan-in node — gives the requirements graph a structural
     seam where story state aggregates into project state, which the
     graph projector uses to lay out late_project nodes at the bottom band)
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Freshness
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.StoryIssueGraph
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Requirements.Verification
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

    with {:ok, ctx} <- Preloader.load(scope) do
      config = CodeMySpec.Configurations.get_or_create(scope)
      compute_whole(scope, ctx, config)
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

  @doc """
  The edge set over a node set, without computing a verdict.

  `compute_topology/3` answers the same question by computing every node first
  and is the right call on a cold vantage, where the nodes have to be computed
  anyway. It is the wrong call when the nodes are already stored: the event
  path was recomputing every node in the project to rebuild edges after a
  shape change, which is the one cost the pass no longer pays.

  `ctx` needs the shape — `Preloader.topology_context/1` is enough — and
  `nodes` are whatever the caller holds for the vantage.
  """
  @spec edges_over(Scope.t(), [Requirement.t()], map(), map()) :: [edge()]
  def edges_over(scope, nodes, ctx, config) do
    ctx =
      ctx
      |> Freshness.with_config(config)
      |> Map.put(:template_edges, template_edges(scope, ctx, config))

    compute_edges(nodes, ctx, config)
  end

  # Settle whichever writer owns the rows this read is about to serve.
  #
  # A read calls this before it answers, and it used to name `GraphWatcher`
  # outright. That is right while the pass writes `requirements` and wrong the
  # moment `graph_event_is_source` flips: the projector then owns the table
  # being read, and a read would settle the pass — now writing the rows — and
  # be served from rows nothing had settled. It also reaches the projector with
  # the vantage the reader named, which `GraphWatcher` has always folded into
  # its next pass as `requested_vantages` and the projector never heard about.
  defp settle_owner(%Scope{active_project_id: project_id} = scope) do
    # Settled if it is running, exactly as the pass side: `GraphWatcher.settle/1`
    # answers `:ok` for a project nothing watches, and `ensure_watching/1` is
    # what starts both writers. A read that started the projector resurrected
    # it after a scenario's teardown had stopped it — a wake task's read,
    # drained after `stop_graph_watchers/0` — and the projector then ran its
    # seed on a sandbox whose owner was gone. So a read starts the writers in
    # one case only: a project with no rows at all (`start_writers/1`).
    if never_projected?(project_id), do: start_writers(scope)
    IncrementalGraph.settle(project_id, [scope.active_working_copy_id])
  end

  # A project nothing has ever projected has no writer to settle, and a read
  # served from its rows is served nothing — which `StoryExecution` reported
  # as "All requirements satisfied" on Metric Flow (182 components, 53 stories,
  # 3,480 marks queued, 0 rows) until an agent was started there, and none
  # was, because the answer read as a finished project.
  #
  # Writers start with an agent (`Agents`) or at boot for continuous projects
  # (`Agents.GraphWake.watch_active_projects/0`); a reader is the third door, and
  # only for a project with no rows at all. That bound is what keeps this from
  # resurrecting a writer a scenario's teardown stopped: a scenario that read
  # after computing has rows. Project rows are written by every seed, so their
  # absence is "never projected" at any vantage.
  @doc "Whether any vantage of this project has ever been projected: its project rows exist."
  @spec projected?(Scope.t()) :: boolean()
  def projected?(%Scope{active_project_id: project_id}) when is_binary(project_id),
    do: not never_projected?(project_id)

  def projected?(%Scope{}), do: false

  defp never_projected?(project_id),
    do:
      not Repo.exists?(
        from(n in CodeMySpec.Requirements.Node, where: n.project_id == ^project_id)
      )

  defp start_writers(scope) do
    case GraphWatcher.ensure_watching(scope) do
      {:ok, _pid} ->
        Logger.info("[Requirements] a read started the writers for #{scope.active_project_id}")

      other ->
        Logger.warning(
          "[Requirements] a read could not start the writers for #{scope.active_project_id}: " <>
            inspect(other)
        )
    end
  end

  # Every template edge in the project, without computing a single node.
  #
  # `compute_all_from_ctx/3` produces these as a by-product of instantiation,
  # and that is the whole reason reusing stored nodes used to mean reusing
  # stored edges: the only way to learn the shape was to redo the work.
  #
  # It never had to be. `build_id_map/3` reads a component's id and its
  # children's ids; `build_template_edges/3` reads the template and that map.
  # Neither opens a file, consults a verdict or takes a fingerprint — which is
  # the same fact `Freshness.topology/2` is built on, applied to the other side
  # of the question.
  defp template_edges(scope, ctx, config) do
    component_template_edges(ctx, config) ++
      Enum.flat_map(ctx.stories, &story_template_edges(&1, ctx, config)) ++
      project_template_edges(scope, config)
  end

  defp component_template_edges(ctx, config) do
    {top_level, children_by_parent} = component_families(ctx)

    Enum.flat_map(top_level, fn component ->
      children = Map.get(children_by_parent, component.id, [])
      original = RequirementDefinitionData.graph_for_type(component.type)
      filtered = filter_definitions_by_config(original, config)

      build_template_edges(filtered, build_id_map(filtered, component, children), original)
    end)
  end

  defp story_template_edges(story, ctx, config) do
    template = maybe_filter_devops(RequirementDefinitionData.story_graph(), config)
    id_map = Map.new(template, fn d -> {d.id, [{"story", story.id, d.name}]} end)
    build_template_edges(template, id_map) ++ StoryIssueGraph.edges(story, ctx, config)
  end

  # The generators one side at a time, for `Edges`.
  #
  # `compute_edges/3` runs every generator and reduces the union. `Edges.over/4`
  # runs the same generators and reduces each entity's edges against the
  # component side, so the two can differ only in the reduction — which is
  # what `edges_derived_per_entity_match_the_pass_test` holds them to.

  @doc """
  The shape with what the story generators read off it — children by parent
  and each type's first requirement — built once per drawing rather than once
  per story.
  """
  @spec edge_context(map(), map()) :: map()
  def edge_context(ctx, config) do
    ctx
    |> Map.put(:children_by_parent, children_by_parent(ctx))
    |> Map.put(:first_def_by_type, first_def_by_type(ctx, config))
  end

  @doc """
  The component side of the edge set as generated: every component's template
  edges and the cross-context edges its dependencies declare. Unreduced;
  `Edges.component_side/3` reduces it.
  """
  @spec component_side_edges(map(), map()) :: [edge()]
  def component_side_edges(ctx, config),
    do: component_template_edges(ctx, config) ++ cross_context_dependency_edges(ctx, config)

  @doc """
  One story's edges as generated, by kind: its own chain, its kickoff into
  the components, the exits back from them, and the pair joining it to the
  project. Unreduced; `Edges.story_side/5` reduces each against the component
  side.
  """
  @spec story_side_edges(map(), map(), map()) :: %{
          template: [edge()],
          kickoff: [edge()],
          exit: [edge()],
          project: [edge()]
        }
  def story_side_edges(story, ctx, config) do
    timing = %{closure: 0, expand: 0, kickoff: 0, exit: 0, components: 0}
    {chain, _timing} = story_chain_edges(story, ctx, config, timing)
    {kickoff, exit} = Enum.split_with(chain, &match?(%{from: {"story", _, _}}, &1))
    one = %{stories: [story]}

    %{
      template: story_template_edges(story, ctx, config),
      kickoff: kickoff,
      exit: exit,
      project: project_to_story_edges(one) ++ story_to_project_edges(one)
    }
  end

  @doc """
  The project's own chain as generated. Unreduced; `Edges.project_side/4`
  reduces it against the stories that bridge it.
  """
  @spec project_side_edges(Scope.t(), map()) :: [edge()]
  def project_side_edges(scope, config), do: project_template_edges(scope, config)

  # The project's own chain. Node-free like the other two, and for the same
  # reason: `compute_project_nodes/3` builds this `id_map` from the project id
  # and the template, then runs ten delegate checkers it does not need.
  defp project_template_edges(scope, config) do
    project = scope.active_project
    template = maybe_filter_devops(RequirementDefinitionData.project_graph(), config)
    id_map = Map.new(template, fn d -> {d.id, [{"project", project.id, d.name}]} end)

    build_template_edges(template, id_map)
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
    components = Map.new(ctx.components, &{&1.id, &1})
    children = Enum.group_by(ctx.components, & &1.parent_component_id)

    stale
    |> Enum.filter(&(elem(&1, 0) == "component"))
    |> Enum.reduce(stale, fn {"component", id}, covered ->
      covered
      |> add_component_template_family(id, components, children)
      |> add_context_ancestor_families(id, components, children)
    end)
  end

  # The template for a context emits child-scoped nodes for its direct
  # children. Recomputing one of those children therefore has to include the
  # context and its siblings, or reduce_to/2 drops the template owner and the
  # child is incorrectly treated as a standalone component.
  defp add_component_template_family(covered, id, components, children) do
    case Map.get(components, id) do
      nil ->
        covered

      component ->
        parent_is_container =
          case Map.get(components, component.parent_component_id) do
            %{type: type} when is_binary(type) -> RequirementsRegistry.has_children?(type)
            _ -> false
          end

        ids =
          if not parent_is_container and RequirementsRegistry.has_children?(component.type),
            do: [id | Enum.map(Map.get(children, id, []), & &1.id)],
            else: [id]

        Enum.reduce(ids, covered, &MapSet.put(&2, {"component", &1}))
    end
  end

  # If that template owner is itself a child of another context, the full pass
  # does not run its own template. Carry the containing context into the narrow
  # context as well, recursively, so the same ownership rules apply at every
  # nested level.
  defp add_context_ancestor_families(covered, id, components, children) do
    add_context_ancestor_families(covered, id, components, children, MapSet.new())
  end

  defp add_context_ancestor_families(covered, id, components, children, seen) do
    seen = MapSet.put(seen, id)

    with %{parent_component_id: parent_id} when not is_nil(parent_id) <- Map.get(components, id),
         %{type: type} when is_binary(type) <- Map.get(components, parent_id),
         true <- RequirementsRegistry.has_children?(type),
         false <- MapSet.member?(seen, parent_id) do
      covered
      |> add_component_template_family(parent_id, components, children)
      |> add_context_ancestor_families(parent_id, components, children, seen)
    else
      _ -> covered
    end
  end

  defp entity_key(%{entity_type: "issue", details: %{"story_id" => id}}), do: {"story", id}
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

  @doc """
  One entity's requirements, computed on their own.

  The event path's unit of work, and the reason it can exist without a
  debounce: a pass narrowed to a single entity does the work that entity earned
  and no more, where the fingerprint pass is whole-project by construction and
  has to coalesce a burst to stay affordable.

  `reduce_to/2` is what makes this the same computation the partial recompute
  already does — it narrows the two lists and leaves the by-id maps whole, so an
  entity computed alone is hashed and answered identically to the same entity
  computed inside a larger stale set. That has to hold or the rows-vs-recompute diff would
  be reporting on this function rather than on the decision it exists to test.

  Project nodes take the whole context deliberately: their checkers read counts
  across the project, so there is nothing to narrow, and `recompute_stale/4`
  rebuilds them unconditionally for the same reason.

  ## A component's unit is its family, not itself

  Returns `{covered, nodes}` rather than just nodes, because for a component the
  two differ. `component_families/1` decides top-level from nested by asking
  whether each component's parent is *in the set it was given* — so a child
  narrowed to itself has no parent there, is classified top-level, and runs its
  own template. Measured on this project: 549 of 1138 components are nested, and
  every one of them computed alone invents an `implementation_file` node that
  the whole-project pass never produces.

  `expand_component_families/2` is what keeps the stale path safe from exactly
  this, and it is why the stale set is always family-closed. The narrow path
  needs the same closure for the same reason, so it calls the same function.

  This is not the debounce coming back. A family is the domain's own atomic
  unit — a context's template owns its children's rows, so those rows cannot be
  produced apart from it — where a debounce window is an arbitrary interval
  chosen to make a whole-project pass affordable. Two unrelated marks still
  compute separately.
  """
  @spec compute_entity(Scope.t(), map(), map(), {String.t(), term()}) ::
          {MapSet.t({String.t(), term()}), [Requirement.t()]}
  def compute_entity(scope, ctx, config, {"component", _id} = entity) do
    covered = expand_component_families(MapSet.new([entity]), ctx)
    {nodes, _} = instantiate_component_graphs(scope, reduce_to(ctx, covered), config)
    {covered, nodes}
  end

  def compute_entity(scope, ctx, config, {"story", _id} = entity) do
    covered = MapSet.new([entity])
    {nodes, _} = compute_story_nodes(scope, reduce_to(ctx, covered), config)
    {covered, nodes}
  end

  # Answers with the project's real id whatever the caller asked with. A mark
  # naming the project carries no id — there is only one — so callers pass
  # `{"project", nil}`, and handing that back would reach `GraphStore.write/3` as
  # `n.project_id == nil`, which Ecto refuses. The nodes below already carry
  # `project.id`; the covered set has to agree with them.
  def compute_entity(scope, ctx, config, {"project", _id}) do
    {nodes, _} = compute_project_nodes(scope, ctx, config)
    {MapSet.new([{"project", scope.active_project.id}]), nodes}
  end

  @doc """
  The project's whole node set and the edges between them, computed and not
  written.

  Edges cannot be projected one entity at a time, which is why the event path
  had none. `compute_edges/3` ends in `Topology.transitive_reduction/1`, and a
  transitive reduction is global by definition: dropping `A → C` requires
  knowing that `A → B → C` exists, so a node instantiated for an unrelated
  entity can *remove* an edge here. There is no narrow version of that
  question.

  What saves it is that edges are a function of the **node set**, not of any
  verdict. A sweep settles answers with `UPDATE`s and cannot add or remove a
  node, so a drain that only swept cannot have moved topology. Only a drain
  that wrote or reaped nodes needs to ask this — which is the same rare set of
  events that already falls back to a recompute: a component created, retyped
  or deleted, a story released or parked.

  Separate from `compute_and_publish/4` because that one also publishes, caches
  and persists. This answers the question and stops.
  """
  @spec compute_topology(Scope.t(), map(), map()) ::
          {[Requirement.t()], [%{from: tuple(), to: tuple()}]}
  def compute_topology(scope, ctx, config) do
    {nodes, enriched_ctx} = compute_nodes(scope, ctx, config)
    {nodes, compute_edges(nodes, enriched_ctx, config)}
  end

  @doc """
  The project's whole node set, computed and not written, with the context
  the computation enriched — what `compute_topology/3` does before the edges.

  On its own so a caller settling several vantages can decide about the edges
  itself: they are a function of the node set and the shape, and every vantage
  of a project shares the shape, so a seed that computed them ten times was
  computing the same set ten times. `edges_over/4` draws them when the caller
  has no set to reuse.
  """
  @spec compute_nodes(Scope.t(), map(), map()) :: {[Requirement.t()], map()}
  def compute_nodes(scope, ctx, config), do: compute_all_from_ctx(scope, ctx, config)

  # The whole graph for this context, in memory. Nothing is written: the
  # projector owns the rows, and this answers readers that compare against a
  # fresh computation (`served_vs_recomputed/1`).
  defp compute_whole(scope, ctx, config) do
    {nodes, enriched_ctx} = compute_all_from_ctx(scope, ctx, config)
    {nodes, compute_edges(nodes, enriched_ctx, config)}
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
  # `node_count` outlived it and no longer guards anything, which is worth
  # saying because the guard is what most of this comment used to describe.
  #
  # It was a distrust mechanism: the publish recorded how many nodes it wrote,
  # a read compared that against what it had loaded, and a short count meant
  # refuse and recompute. It was earned — `Projection.load/3` rebuilds each row
  # against the preloaded context and drops whatever `rehydrate/2` cannot place,
  # so a hit could return a strict subset with nothing amiss in either the write
  # or the read. Measured on story 1062: 2009 nodes computed, 1844 served,
  # stable across reads, back to 2009 on the next recompute, all under one
  # `computed_at` (7a6b92e3) — two graphs wearing one timestamp, which criterion
  # 3246 forbids and 3358 states directly.
  #
  # Reads stopped recomputing, and the comparison went with them. `published_at/2`
  # is the only thing that still reads the cache row and it takes the timestamp
  # and discards the count (`{:ok, _nodes, at}`), so nothing anywhere counts the
  # rows in order to doubt them. Criterion 3422 — "stored requirements are
  # trusted rather than counted" — is therefore a description of this code
  # rather than an argument with it, which is how issue `34b3ce00` resolved:
  # not by choosing a side, but because the vantage alignment that caused the
  # short reads removed the reason for the guard.
  #
  # The measurement that settled it, taken 2026-09-21 across every rotation of
  # `web.log` and `server.log`: **212 publishes, zero** `the projection does not
  # round-trip`. The drop the guard existed to catch does not happen any more.
  #
  # The count is still written. `GraphCache`'s own doc says why — a reader
  # finding no rows can tell "nothing to do" from "the write did not land" —
  # and no reader does that today. Left in place rather than migrated out,
  # because a column that costs a integer per publish is cheaper than being
  # wrong about who might want it.

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
  def cached_graph(%Scope{} = scope, opts \\ []) do
    {graph, _actionable, computed_at} = cached_graph_with_actionable(scope, opts)
    {graph, computed_at}
  end

  @doc """
  `cached_graph/1` plus the actionable set, for readers that want both without
  paying for the preload twice.

  Returns `{{nodes, edges}, actionable, computed_at}`.

  ## Options

    * `:settle` — reconcile the watcher's queue before answering. Defaults to
      `true`, and every production reader wants the default.

  Rule `ea5b6838`: a read with observations still pending recomputes before it
  answers. *Pending* — this waits for work that has already been asked for,
  which is not the same as re-deriving what nobody asked for. The second is
  what this function used to do, and it is what made a silent writer invisible:
  whoever read next repaired the graph, so a writer that announced nothing
  produced the same answer as one that worked. All eighteen criteria on story
  1063 passed against seven writers that announce nothing.

  `settle: false` exists for the test that has to see that difference. A read
  that skips the queue answers from the rows exactly as they stand, so a write
  that announced nothing is visibly still missing rather than quietly repaired
  on the way past.
  """
  @spec cached_graph_with_actionable(Scope.t(), keyword()) ::
          {{[Requirement.t()], [edge()]}, [Requirement.t()], DateTime.t() | nil}
  def cached_graph_with_actionable(%Scope{} = scope, opts \\ []) do
    scope = normalize_vantage(scope)

    if Keyword.get(opts, :settle, true) do
      settle_owner(scope)
    end

    with {:ok, ctx} <- Preloader.load(scope) do
      serve_with_actionable(scope, ctx)
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

  `served_from` is `"cache"` when rows answered this read and `"empty"` when
  there are none at this vantage.

  It used to say `"computed"` for the second case, which was true when a read
  computed its own answer on a miss. Reads compute nothing now, so that value
  described a read that had produced a graph when what had actually happened
  was the opposite — nothing has ever computed this vantage, and the caller was
  handed an empty answer. On a diagnostic surface whose whole job is saying
  whether the graph is current, that is the one word it must not get wrong.
  """
  @spec cached_graph_with_actionable_metrics(Scope.t()) ::
          {{[Requirement.t()], [edge()], [Requirement.t()]}, map()}
  def cached_graph_with_actionable_metrics(%Scope{} = scope) do
    scope = normalize_vantage(scope)

    # Settle, like every other read. This went straight to `serve_with_actionable/2`
    # — the private path, below the settle — and so answered from rows that a
    # pending observation had already moved past. The requirements graph page is
    # the most-looked-at reader there is, so it showed a graph one write behind
    # for a whole debounce window, which reads as the graph being wrong rather
    # than as the page being early. Ten of story 562's spex caught it: a child
    # implementation deleted, the sync announcing it, and the page still
    # rendering the node satisfied.
    settle_owner(scope)

    {us_preload, {:ok, ctx}} = :timer.tc(fn -> Preloader.load(scope) end)

    {us_graph, {{nodes, edges}, actionable, computed_at}} =
      :timer.tc(fn -> serve_with_actionable(scope, ctx) end)

    metrics = %{
      preload_ms: div(us_preload, 1000),
      graph_ms: div(us_graph, 1000),
      node_count: length(nodes),
      edge_count: length(edges),
      computed_at: computed_at,
      served_from: if(computed_at, do: "cache", else: "empty")
    }

    {{nodes, edges, actionable}, metrics}
  end

  # A read answers from the rows. It does not recompute.
  #
  # It used to do both jobs, and only one of them was ever legitimate. The
  # honest one is "process what I have been told" — `actionable_count/2` does
  # it, by calling `GraphWatcher.settle/1` before it reads, and rule
  # `ea5b6838` is exactly that: a read with observations still pending
  # recomputes before it answers. *Pending.*
  #
  # The other was "re-derive what nobody told me": fingerprint the whole
  # project, diff every entity, recompute whatever moved. That is what this
  # function used to do on every render, and it is the reason a writer that
  # publishes nothing is indistinguishable from one that works. The reader
  # repaired the graph, then the assertion credited the writer.
  #
  # It also made the specs lie. All eighteen of story 1021's scenarios pass
  # today — "a story being released moves the graph", "a criterion being
  # added moves the graph" — against writers that provably never announce,
  # because each scenario writes, reads, and asserts the graph moved. The read
  # was doing the moving.
  #
  # `c228dbdc` is the rule being broken: a domain event is trusted, and the
  # graph does not re-verify that something really changed. Re-deriving is
  # re-verification of everything, every time.
  #
  # So: load the rows and answer. Freshness comes from
  # the rows themselves — `checked_at` is per requirement and always has been,
  # which is the direction story 1020's notes already name: "is this current"
  # is a per-row question.
  defp serve_with_actionable(scope, ctx) do
    {nodes, edges} = Projection.load(scope, ctx)

    # The un-enriched ctx, as in `next_actionable/1`: `actionable_from/3` reads
    # `ctx.components` and `ctx.stories`, both of which the preloader supplies.
    {{nodes, edges}, actionable_from(nodes, edges, ctx), last_checked_at(nodes)}
  end

  @doc """
  What is served, against every entity recomputed from its inputs now.

  The instrument for the event path. It settles rows from observations and
  stamps no fingerprint, so `stale_entities_report/1` — which judges a row by
  the stamp the pass wrote on it — reads every row the event path has touched
  as stale, for good: 447 of 1,134 components on dev, every one of them
  right. This asks the only question that outlives the pass: recomputed from
  the domain this minute, does every requirement and every edge agree with
  what is being served? Nothing is written. Expensive on purpose — one whole
  computation, on demand, by one reader.
  """
  @spec served_vs_recomputed(Scope.t()) :: map()
  def served_vs_recomputed(%Scope{} = scope) do
    scope = scope |> normalize_vantage() |> with_project()
    {:ok, ctx} = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {served, served_edges} = Projection.load(scope, ctx)
    {computed, computed_edges} = compute_topology(scope, ctx, config)

    served_by_key = Map.new(served, &{node_key(&1), Verification.behavior(&1)})
    computed_by_key = Map.new(computed, &{node_key(&1), Verification.behavior(&1)})
    served_keys = MapSet.new(Map.keys(served_by_key))
    computed_keys = MapSet.new(Map.keys(computed_by_key))

    missing = MapSet.difference(computed_keys, served_keys)
    extra = MapSet.difference(served_keys, computed_keys)

    disagree =
      served_keys
      |> MapSet.intersection(computed_keys)
      |> Enum.filter(&(Map.fetch!(served_by_key, &1) != Map.fetch!(computed_by_key, &1)))

    actionable_differences =
      Enum.flat_map(RoleProfile.roles(), fn role ->
        actual = actionable_keys(served, served_edges, ctx, role)
        expected = actionable_keys(computed, computed_edges, ctx, role)

        Enum.map(
          MapSet.difference(expected, actual),
          &"#{role} work not offered: #{audit_label(&1)}"
        ) ++
          Enum.map(
            MapSet.difference(actual, expected),
            &"#{role} extra work offered: #{audit_label(&1)}"
          )
      end)

    served_edge_set = MapSet.new(served_edges, &{&1.from, &1.to})
    computed_edge_set = MapSet.new(computed_edges, &{&1.from, &1.to})
    edges_missing = MapSet.difference(computed_edge_set, served_edge_set)
    edges_extra = MapSet.difference(served_edge_set, computed_edge_set)

    %{
      actionable_disagree: length(actionable_differences),
      served: map_size(served_by_key),
      computed: map_size(computed_by_key),
      missing: MapSet.size(missing),
      extra: MapSet.size(extra),
      disagree: length(disagree),
      served_edges: MapSet.size(served_edge_set),
      computed_edges: MapSet.size(computed_edge_set),
      edges_missing: MapSet.size(edges_missing),
      edges_extra: MapSet.size(edges_extra),
      sample:
        Enum.map(missing, &"not served: #{audit_label(&1)}") ++
          Enum.map(extra, &"served, not recomputed: #{audit_label(&1)}") ++
          Enum.map(disagree, fn key ->
            fields = Verification.changed_fields(served_by_key[key], computed_by_key[key])
            "disagrees: #{audit_label(key)} (#{Enum.join(fields, ", ")})"
          end) ++
          actionable_differences ++
          Enum.map(edges_missing, &"edge not served: #{audit_edge(&1)}") ++
          Enum.map(edges_extra, &"edge served, not recomputed: #{audit_edge(&1)}")
    }
  end

  defp actionable_keys(nodes, edges, ctx, role) do
    nodes
    |> actionable_for_role_from(edges, ctx, role)
    |> MapSet.new(&node_key/1)
  end

  # A reader that named only the project id — the dev page — carries neither
  # the project nor its account, and both are read: the project's own chain is
  # instantiated from `scope.active_project`, and the checkers read through
  # the account (`Questions.list_questions_for_story/2` answers nothing to a
  # scope with none). The first cut carried only the project and reported 19
  # stories' `questions_answered` as disagreeing with rows that were right.
  defp with_project(%Scope{active_project: %{id: _}, active_account_id: account} = scope)
       when not is_nil(account),
       do: scope

  defp with_project(%Scope{active_project_id: id} = scope) do
    project = Repo.get!(CodeMySpec.Projects.Project, id)
    account = Repo.get!(CodeMySpec.Accounts.Account, project.account_id)

    %{
      scope
      | active_project: project,
        active_account: account,
        active_account_id: account.id
    }
  end

  defp audit_label({"component", id, name}), do: "component:#{String.slice(id, 0, 8)}/#{name}"
  defp audit_label({type, id, name}), do: "#{type}:#{id}/#{name}"
  defp audit_edge({from, to}), do: "#{audit_label(from)} -> #{audit_label(to)}"

  @doc """
  The requirement names the templates define for the entities in `ctx`, by
  entity type — for stories and the project the whole filtered template, for
  each top-level component type its parent- and self-scoped definitions.

  What `GraphStore.definitions_covered?/2` compares a vantage's rows against: a
  release that adds or removes a definition leaves rows that no handler can
  bring in line, since handlers settle rows and never create them. Child-scoped
  definitions are left out because whether a child carries one depends on the
  child's type, and a comparison that can be wrong is worse than a narrower one
  that cannot.
  """
  @spec defined_names(map(), map()) :: %{
          story: MapSet.t(String.t()),
          project: MapSet.t(String.t()),
          component: %{String.t() => MapSet.t(String.t())},
          entities: %{{String.t(), term()} => MapSet.t(String.t())}
        }
  def defined_names(ctx, config) do
    {top_level, _children_by_parent} = component_families(ctx)

    component =
      top_level
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Map.new(fn type ->
        names =
          type
          |> RequirementDefinitionData.graph_for_type()
          |> filter_definitions_by_config(config)
          |> Enum.filter(&(&1.node_scope in [:parent, :self]))
          |> MapSet.new(& &1.name)

        {type, names}
      end)

    %{
      story: template_names(RequirementDefinitionData.story_graph(), config),
      project: template_names(RequirementDefinitionData.project_graph(), config),
      component: component,
      entities: defined_entities(ctx, config)
    }
  end

  @doc """
  Expected requirement names for each story and component in a loaded context.

  This derives membership from the same filtered templates and parent/child
  split used by graph computation. It does not run requirement checkers, so it
  can identify missing rows without performing verdict work.
  """
  @spec defined_entities(map(), map()) :: %{{String.t(), term()} => MapSet.t(String.t())}
  def defined_entities(ctx, config) do
    entities =
      Map.new(ctx.components, &{{"component", &1.id}, MapSet.new()})
      |> Map.merge(Map.new(ctx.stories, &{{"story", &1.id}, MapSet.new()}))

    {top_level, children_by_parent} = component_families(ctx)

    entities =
      Enum.reduce(top_level, entities, fn component, acc ->
        template =
          component.type
          |> RequirementDefinitionData.graph_for_type()
          |> filter_definitions_by_config(config)

        own_names =
          template
          |> Enum.filter(&(&1.node_scope in [:parent, :self]))
          |> MapSet.new(& &1.name)

        acc = Map.update!(acc, {"component", component.id}, &MapSet.union(&1, own_names))

        Enum.reduce(Map.get(children_by_parent, component.id, []), acc, fn child, child_acc ->
          child_names =
            template
            |> Enum.filter(&(&1.node_scope == :child))
            |> filter_defs_for_child_type(child.type)
            |> MapSet.new(& &1.name)

          Map.update!(child_acc, {"component", child.id}, &MapSet.union(&1, child_names))
        end)
      end)

    story_names = template_names(RequirementDefinitionData.story_graph(), config)

    Map.new(entities, fn
      {{"story", _id} = key, _names} -> {key, story_names}
      {key, names} -> {key, names}
    end)
  end

  defp template_names(template, config),
    do: template |> maybe_filter_devops(config) |> MapSet.new(& &1.name)

  # When the rows were last computed, taken from the rows.
  #
  # Replaces a whole-graph `computed_at` read off the cache row behind a
  # whole-project fingerprint. A single timestamp for 2000 requirements could
  # only ever answer "did anything anywhere recompute", which is why
  # `refute after == before` passed for every writer including the silent ones.
  defp last_checked_at(nodes) do
    nodes
    |> Enum.map(& &1.checked_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ats -> Enum.max(ats, NaiveDateTime)
    end
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

  @doc """
  The same actionable set, computed as one role sees it.

  `actionable_from/3` blocks a node when *any* transitive prerequisite is
  unsatisfied, whoever it belongs to. That is right inside one entity's chain and
  wrong across the project: an untriaged issue queue is product's, and it was
  making every story's coding work unactionable for roles that could not clear
  it. Measured 2026-09-15: `get_next_requirement` offered TriageIssues and
  nothing else while five spex criteria sat red on a coding agent's own
  checkout, and the agent reported "the graph holds no work for its role"
  throughout.

  So a block still travels, but only where it means something to the role asking:

    * **Same entity** — a story's own chain clamps regardless of role.
      `three_amigos_complete` is product's and `bdd_specs_exist` is coding's, and
      specs for a story genuinely wait on that story's Three Amigos.
    * **Same role** — a role's own unfinished work still orders itself, across
      entities as before.

  A prerequisite that is neither orders the work and does not clamp it. Story
  1005's rule, criterion 3491.

  This does not make anything actionable that was unsatisfied on its own merits:
  `actionable_from/3`'s other conditions are unchanged, so a node still has to be
  unsatisfied, have a task that can satisfy it, and be tethered.

  `seeds` is which unsatisfied nodes clamp. `:all` is every one. `:local` is
  story and component nodes only, never a project-level one: the view of an
  agent bound to its active story (4292518a), which is never offered project
  work and so is not held behind it. A story's own unsatisfied node still
  clamps its descendants there. One traversal either way.
  """
  @spec actionable_for_role_from([Requirement.t()], [edge()], map(), atom(), :all | :local) ::
          [Requirement.t()]
  def actionable_for_role_from(nodes, edges, ctx, role, seeds \\ :all) do
    role_names = MapSet.new(RequirementsRegistry.requirement_names_for_role(role))

    blocked = blocked_for_role(nodes, edges, role_names, seeds)
    component_priority = build_component_priority_map(ctx)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        not Requirement.waiting?(n) and
        MapSet.member?(role_names, n.name) and
        not untethered_component?(n, component_priority) and
        not MapSet.member?(blocked, node_key(n))
    end)
    |> sort_by_story_priority(ctx)
  end

  # Forward from each unsatisfied node, carrying who it belongs to, so the
  # decision to clamp is made per reachable node rather than once per seed. A
  # seed blocks a descendant when they share an entity, or when the seed is this
  # role's own work.
  defp blocked_for_role(nodes, edges, role_names, seeds) do
    outgoing =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge.to], &[edge.to | &1])
      end)

    entity_of = Map.new(nodes, fn n -> {node_key(n), entity_key(n)} end)

    nodes
    |> Enum.filter(&seed?(&1, seeds))
    |> Enum.reduce(MapSet.new(), &block_from_seed(&1, &2, outgoing, entity_of, role_names))
  end

  @doc """
  Whether an unsatisfied `node` holds back what it reaches, under `seeds`.

    * `:all` — every unsatisfied node does.
    * `:local` — all but project-level ones (4292518a, unclamped).
    * `{:story, story_id, component_ids}` — only the bound story's own nodes
      and its member components' (`story_component_ids/2`). Another story's
      unmet `bdd_specs_exist`, reached through a kickoff edge, held story
      1084's coder on work nobody bound to 1084 could take.
  """
  def seed?(%{satisfied: true}, _seeds), do: false
  def seed?(%{entity_type: "project"}, :local), do: false

  def seed?(%{entity_type: "story", entity_id: id}, {:story, story_id, _ids}),
    do: to_string(id) == to_string(story_id)

  def seed?(%{entity_type: "component", entity_id: id}, {:story, _story_id, ids}),
    do: MapSet.member?(ids, id)

  def seed?(%{entity_type: "issue", details: %{"story_id" => id}}, {:story, story_id, _ids}),
    do: id == story_id

  def seed?(_node, {:story, _story_id, _ids}), do: false
  def seed?(_node, _seeds), do: true

  defp block_from_seed(seed, acc, outgoing, entity_of, role_names) do
    seed_entity = entity_key(seed)
    seeds_own_role = MapSet.member?(role_names, seed.name)

    outgoing
    |> Map.get(node_key(seed), [])
    |> reachable(outgoing, MapSet.new())
    |> Enum.filter(&clamps?(seeds_own_role, Map.get(entity_of, &1), seed_entity))
    |> Enum.into(acc)
  end

  # Same role, or same entity. Anything else orders the work without clamping it.
  defp clamps?(true, _descendant_entity, _seed_entity), do: true
  defp clamps?(false, entity, entity), do: true
  defp clamps?(false, _descendant_entity, _seed_entity), do: false

  defp reachable([], _outgoing, seen), do: seen

  defp reachable([key | rest], outgoing, seen) do
    if MapSet.member?(seen, key) do
      reachable(rest, outgoing, seen)
    else
      reachable(Map.get(outgoing, key, []) ++ rest, outgoing, MapSet.put(seen, key))
    end
  end

  @doc "Actionability against the complete graph, ordered using the supplied story context."
  def actionable_from(nodes, edges, ctx) do
    satisfaction_map =
      Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    blocked_descendants = compute_blocked_descendants(edges, satisfaction_map)

    component_priority = build_component_priority_map(ctx)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        not Requirement.waiting?(n) and
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
      {nodes, _edges} = compute_whole(scope, ctx, config)
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
  # Kickoff targets child implementations for contexts, or the component's
  # own implementation when there are no implementable children. Live contexts
  # are containers only. A context's own implementation is its exit; a live
  # context exits through its children's implementations.
  # `children_by_parent` is built once here rather than per story.
  #
  # `story_components/2` needs it and used to group all of
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

  @doc """
  A story's subgraph: its surface, the surface's descendants, and everything
  those depend on, transitively. The one set of a story's components — kickoff
  gating, priority within a story, what a bound team is offered, and what holds
  it (4292518a).

  A dependency context brings its direct children, since a context is
  implemented through them; nothing recurses further. Expanding every
  dependency's descendants, and their descendants' dependencies, made story
  1083 (surface `CodeMySpec.Architecture`) 568 of 1,319 components, phantom
  modules of retired stories among them (d1a69b4e).
  """
  def story_component_ids(story, ctx) do
    story |> story_components(ctx) |> MapSet.new(& &1.id)
  end

  defp story_components(story, ctx) do
    case Map.get(ctx.components_by_id, story.component_id) do
      nil ->
        []

      surface ->
        children_by_parent = ctx[:children_by_parent] || children_by_parent(ctx)

        subtree = [surface | descendants_of(surface, children_by_parent, MapSet.new())]

        closure =
          subtree |> Enum.flat_map(&transitive_dep_closure(&1, ctx)) |> Enum.uniq_by(& &1.id)

        (closure ++ Enum.flat_map(closure, &context_children(&1, children_by_parent)))
        |> Enum.uniq_by(& &1.id)
        |> Enum.reject(&phantom?(&1, ctx))
    end
  end

  # A context is implemented through its children (its kickoff targets them),
  # so depending on one is depending on its direct children too — story 561,
  # criteria 3590 and 3601. Direct only, and not their dependencies: John, for
  # d1a69b4e.
  @containers ~w(context live_context)

  defp context_children(%{type: type, id: id}, children_by_parent) when type in @containers,
    do: Map.get(children_by_parent, id, [])

  defp context_children(_component, _children_by_parent), do: []

  # `:discovered` means ComponentSync found this component by scanning a file;
  # one with none on this project's own Files records cannot be a discovery
  # here. `prune_unreferenced/2` (Files.ComponentSync) deliberately keeps a
  # discovered component whose code vanished as long as something still
  # references it — an authored parent, a dependency, a story — so that
  # another working copy that still has the file does not lose it. That
  # design means a component synced into existence by a *different*
  # checkout's files can sit in this shared, project-wide table indefinitely,
  # referenced only by its parent context, and `context_children/2` above
  # has no way to tell that apart from a component this copy genuinely has
  # not implemented yet (issue 92f5d6ee and its cluster: 6bb47d00, 62a6bd5f,
  # 0555b8a3). An `:authored` component is never filtered — it is real
  # architecture regardless of whether its file has landed yet.
  #
  # Lightweight topology loads carry checkout-specific file membership;
  # full loads carry the records. Both must exclude exactly the same ghosts.
  defp phantom?(%{provenance: :discovered, id: id}, %{file_component_ids: ids}),
    do: not MapSet.member?(ids, id)

  defp phantom?(%{provenance: :discovered, id: id}, %{files_by_component: files_by_component}),
    do: Map.get(files_by_component, id, []) == []

  defp phantom?(_component, _ctx), do: false

  defp story_chain_edges(story, ctx, config, acc) do
    case Map.get(ctx.components_by_id, story.component_id) do
      nil ->
        {[], acc}

      surface ->
        {closure_us, kickoff_components} = :timer.tc(fn -> story_components(story, ctx) end)
        expand_us = 0

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
    first = first_def_for(comp.type, config, ctx)

    # A context without implementable children starts at its own implementation.
    first =
      case first do
        %{node_scope: :child, name: name} ->
          if Enum.any?(direct_children(comp, ctx), &child_supports_def_name?(&1, name)) do
            first
          else
            comp.type
            |> RequirementDefinitionData.graph_for_type()
            |> Enum.find(&(&1.node_scope in [:parent, :self]))
          end

        _ ->
          first
      end

    case first do
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

  # ready_for_qa is gated on the LEAVES of the surface's
  # orchestration tree:
  # - leaf surface (template has no :child defs): the surface's own
  #   last :self def feeds ready_for_qa.
  # - container surface (template has :child defs): each direct
  #   child's terminal feeds ready_for_qa. Sibling children
  #   with cross-context deps collapse via transitive reduction —
  #   only the deepest leaf survives.
  #
  # The gate then feeds qa_complete via the intra-story prerequisite
  # edge, so a story cannot reach a QA sub-agent before its own specs
  # have gone green. bab2f792 pointed these terminals straight at
  # qa_complete when the gate was removed; this puts the seam back.
  defp surface_exit_edge(surface, story, ctx, config) do
    own_terminal =
      surface.type
      |> RequirementDefinitionData.graph_for_type()
      |> Enum.any?(&(&1.node_scope in [:parent, :self]))

    if own_terminal do
      leaf_exit_edge(surface, story, config)
    else
      container_exit_edges(surface, story, ctx, config)
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
            to: {"story", story.id, "ready_for_qa"}
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
              to: {"story", story.id, "ready_for_qa"}
            }
          ]
      end
    end)
  end

  defp direct_children(parent, ctx) do
    ctx.children_by_parent
    |> Map.get(parent.id, [])
    |> Enum.reject(&phantom?(&1, ctx))
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

  # Every recorded dependency gates the dependent's first requirement.
  # Ownership does not imply that a parent repeats its children's dependencies.
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
    case Map.get(ctx.components_by_id, dep.id) do
      nil ->
        []

      dep_comp ->
        sources = component_boundary(dep_comp, :exit, ctx, config)
        targets = component_boundary(comp, :entry, ctx, config)

        for source <- sources, target <- targets, source != target do
          %{from: source, to: target}
        end
    end
  end

  # Container templates can begin or end at child work. Resolve those scopes
  # before making an edge; a live context has no node of its own to point at.
  defp component_boundary(comp, direction, ctx, config) do
    definitions =
      comp.type
      |> RequirementsRegistry.get_requirements_for_type()
      |> filter_definitions_by_config(config)

    definition = if direction == :entry, do: List.first(definitions), else: List.last(definitions)
    boundary_nodes(comp, definition, definitions, ctx)
  end

  defp boundary_nodes(_comp, nil, _definitions, _ctx), do: []

  defp boundary_nodes(comp, %{node_scope: :child, name: name}, definitions, ctx) do
    children = Enum.filter(direct_children(comp, ctx), &child_supports_def_name?(&1, name))

    case children do
      [] ->
        own = Enum.find(definitions, &(&1.node_scope in [:parent, :self]))
        boundary_nodes(comp, own, definitions, ctx)

      children ->
        Enum.map(children, &{"component", &1.id, name})
    end
  end

  defp boundary_nodes(comp, %{name: name}, _definitions, _ctx),
    do: [{"component", comp.id, name}]

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
    # Stamped here rather than by the caller: this is a function that *hashes*
    # an entity, and the comparison and the write have to agree exactly or
    # every row reads stale forever. `Freshness.with_config/2` is idempotent,
    # so a caller that already stamped pays a map write.
    ctx = Freshness.with_config(ctx, config)

    {top_level, children_by_parent} = component_families(ctx)

    top_level
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

  # Who runs a template, and for whom.
  #
  # Only context-shaped types (templates with :child scope defs) own their
  # nested components for template purposes. A component nested under a
  # non-context parent (e.g. a context whose namespace happens to live under an
  # `infrastructure` umbrella like `MarketMySpec`) is still top-level and must
  # run its own template — otherwise every component below the umbrella gets
  # dropped from the requirement graph and the project shows 0/0 everywhere.
  #
  # Shared with `barren_components/2` rather than restated there. The question
  # "which components can produce a row" is answered by exactly this split plus
  # the config filter, and a second copy of the split would be a second copy
  # that could drift — with the drift showing up as entities recomputed forever,
  # which is the failure this whole neighbourhood exists to remove.
  defp component_families(ctx) do
    container_ids =
      ctx.components
      |> Enum.filter(&RequirementsRegistry.has_children?(&1.type))
      |> MapSet.new(& &1.id)

    {children, top_level} =
      Enum.split_with(ctx.components, fn c ->
        c.parent_component_id && MapSet.member?(container_ids, c.parent_component_id)
      end)

    {top_level, Enum.group_by(children, & &1.parent_component_id)}
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

    {parent_id, parent_name} = Requirement.orchestration_parent(definition, entity, parent)

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
      owner_component_type: owner_component_type(entity, parent),
      node_scope: definition.node_scope,
      prerequisites: [],
      details: Requirement.normalize_details(result.details)
    }
  end

  # Which template produced this node: a `:child` def comes from the parent's,
  # everything else from the entity's own. Stored on the row because the name
  # alone matches two different definitions — see `Projection.definition_for/3`.
  defp owner_component_type(entity, nil), do: entity.type
  defp owner_component_type(_entity, parent), do: parent.type

  # Only stamp child_defs whose names exist in the child's own graph template.
  defp filter_defs_for_child_type(defs, child_type) do
    allowed =
      child_type
      |> RequirementDefinitionData.graph_for_type()
      |> MapSet.new(& &1.name)

    Enum.filter(defs, &(&1.name in allowed))
  end

  defp compute_story_nodes(scope, ctx, config) do
    # Stamped here rather than by the caller: this is a function that *hashes*
    # an entity, and the comparison and the write have to agree exactly or
    # every row reads stale forever. `Freshness.with_config/2` is idempotent,
    # so a caller that already stamped pays a map write.
    ctx = Freshness.with_config(ctx, config)

    # Only the devops filter applies to story templates — the
    # specs/reviews/tests filters are component-scoped by design
    # Component and story requirements have distinct templates.
    # devops: :off drops the deploy requirement from every story.
    template = maybe_filter_devops(RequirementDefinitionData.story_graph(), config)
    project = scope.active_project

    {nodes, edges} =
      Enum.flat_map_reduce(ctx.stories, [], fn story, all_edges ->
        files = Map.get(ctx.files_by_story, story.id, [])

        # Stamped once per story rather than once per requirement: every
        # requirement of a story reads the same slice of the context, so they
        # go stale together and hashing it seven times would answer the same
        # question seven ways.
        fingerprint = story_fingerprint(ctx, story)

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

        nodes = nodes ++ StoryIssueGraph.nodes(story, ctx, config, fingerprint)
        edges = story_template_edges(story, ctx, config)
        {nodes, all_edges ++ edges}
      end)

    # Stash edges — they'll be merged into template_edges
    {nodes, edges}
  end

  # `nil` when the context says it was not loaded to answer this.
  #
  # `Preloader.load_story/3` omits `delegated_inputs` because nothing but
  # `Freshness` and `GraphFingerprint` read it, and hashing a narrow context
  # would produce a *plausible* fingerprint that is not the one a whole pass
  # produces. That is worse than no fingerprint: it looks comparable and is not,
  # so a later reader could skip a row on the strength of it.
  #
  # `nil` already carries the right meaning — `Node`'s `inputs_fingerprint` doc
  # says it "reads as 'no basis to skip it' rather than as 'unchanged'" — which
  # is exactly true of a row the event path wrote.
  defp story_fingerprint(%{skip_fingerprints: true}, _story), do: nil
  defp story_fingerprint(ctx, story), do: Freshness.story(ctx, story)

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
          details: Requirement.normalize_details(result.details),
          # Stamped like every other entity, so a pass can tell whether the
          # project's own inputs moved instead of assuming they did. Without
          # this there is nothing stored to compare and project nodes are
          # rebuilt unconditionally — ten delegate checkers on every pass,
          # which is the floor cost of observing anything at all.
          inputs_fingerprint: Freshness.project(ctx)
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
                       "qa_journey_execute"
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

  # Depth is the longest prerequisite chain behind a node. `ready_for_qa`
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
    {tier, {0, 0}, Map.get(def_order, name, 999)}
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
    rank = if story, do: story_rank(story), else: {999, 0}
    {1, rank, story_req_depth(name)}
  end

  defp priority_sort_key(
         %{entity_type: "issue", details: %{"story_id" => id}},
         stories,
         comp,
         order
       ),
       do:
         priority_sort_key(
           %{entity_type: "story", entity_id: id, name: "ready_for_qa"},
           stories,
           comp,
           order
         )

  defp priority_sort_key(
         %{entity_type: "component", entity_id: id},
         _story,
         comp_priority,
         _order
       ) do
    case Map.fetch(comp_priority, id) do
      {:ok, rank} -> {1, rank, 0}
      :error -> {1, {999, 0}, 1}
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
  # A story's rank: its priority, then its age. Two stories at the same
  # priority are not tied — the older one leads — and `min/2` over this pair
  # gives exactly that, since a lower priority wins and an equal priority falls
  # through to the smaller timestamp.
  #
  # The age used to be missing entirely, so two components inheriting the same
  # priority produced identical sort keys. `Enum.sort_by/2` is stable, so the
  # winner was whatever order the nodes arrived in — and that order is
  # `kept ++ fresh` from `recompute_stale/3`, which depends on which entities
  # happened to be stale on that pass. The answer to "which story leads" was
  # therefore decided by recompute bookkeeping, and changed run to run.
  #
  # Criterion 5901 is named for the rule this implements: same priority, oldest
  # created_at wins.
  defp story_rank(story) do
    {story.priority || 999, story_age(story)}
  end

  defp story_age(%{inserted_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp story_age(%{inserted_at: %NaiveDateTime{} = at}),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp story_age(_story), do: 0

  defp build_component_priority_map(%{execution_component_ids: ids, stories: [story]}) do
    Map.new(ids, &{&1, story_rank(story)})
  end

  defp build_component_priority_map(ctx) do
    # Direct: story.component_id → component
    direct =
      ctx.stories
      |> Enum.filter(& &1.component_id)
      |> Enum.reduce(%{}, fn story, acc ->
        rank = story_rank(story)
        Map.update(acc, story.component_id, rank, &min(&1, rank))
      end)

    # Spread priority to dependencies of surface components
    with_deps =
      ctx.stories
      |> Enum.filter(& &1.component_id)
      |> Enum.reduce(direct, fn story, acc ->
        surface = Map.get(ctx.components_by_id, story.component_id)
        rank = story_rank(story)

        deps =
          case surface && surface.dependencies do
            %Ecto.Association.NotLoaded{} -> []
            deps when is_list(deps) -> deps
            _ -> []
          end

        Enum.reduce(deps, acc, fn dep, inner_acc ->
          Map.update(inner_acc, dep.id, rank, &min(&1, rank))
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

  # Only deployment configuration changes which graph definitions exist.
  defp filter_definitions_by_config(definitions, config) do
    maybe_filter_devops(definitions, config)
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
  defp maybe_filter_devops(definitions, config) do
    case ProjectConfiguration.devops_level(config) do
      :off -> Enum.reject(definitions, &(&1.artifact_type == :deployment))
      _on -> definitions
    end
  end
end
