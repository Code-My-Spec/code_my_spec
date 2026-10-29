defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph — nodes AND edges — from Files and the project's records.

  The graph is entity-agnostic: edges represent real dependencies regardless of
  whether they cross entity boundaries. There are four kinds of edges:

  1. **Same-entity prerequisites**: ordered story and project requirements
  2. **Project → story**: project.qa_setup → story.component_linked (the
     whole-project gate that opens story-level work)
  3. **Story → component tree**: bdd_specs_exist → component's first req;
     component's terminal req → ready_for_qa → qa_complete
  4. **Stories → project**: each story's qa_complete → qa_journey_plan, the
     project-level fan-in where story state aggregates into project state

  Pure: nothing here writes. `IncrementalGraph` is the writer; see
  knowledge/requirements_graph, "Writers and readers".
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  # Where the entities meet: a component's terminal work feeds its story at
  # `@component_join`, and a story's QA feeds the project at `@story_join`.
  @component_join "ready_for_qa"
  @story_join "qa_journey_plan"

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

  # Why: resolved once, before `Preloader` sees the scope, so the computation
  # reads and stores under one checkout identity rather than blending every
  # checkout's files. See knowledge/requirements_graph, "Vantages".
  defp normalize_vantage(%Scope{} = scope),
    do: %{scope | active_working_copy_id: Projection.vantage(scope)}

  # Settle the writer before serving its rows, at the vantage the reader named.
  @doc """
  Wait for the writer to apply what is pending at the scope's vantage, as every
  read here does first. For a reader that serves stored rows itself.
  """
  @spec settle(Scope.t()) :: :ok
  def settle(%Scope{} = scope) do
    scope |> normalize_vantage() |> settle_owner()
    :ok
  end

  defp settle_owner(%Scope{active_project_id: project_id} = scope) do
    # Why: a read starts the writer for a project with no rows at all, or one
    # whose projector died without being stopped; not one that was stopped, or
    # it would resurrect a projector a test's teardown had stopped.
    # See knowledge/requirements_graph, "Writers and readers".
    cond do
      never_projected?(project_id) ->
        start_writers(scope)

      IncrementalGraph.orphaned?(project_id) ->
        Logger.warning(
          "[Requirements] the projector for #{project_id} died without stopping; " <>
            "its rows were not being kept current, restarting it"
        )

        start_writers(scope)

      true ->
        :ok
    end

    IncrementalGraph.settle(project_id, [scope.active_working_copy_id])
  end

  # Why: zero rows must not read as "All requirements satisfied". Every seed
  # writes project rows, so their absence means never projected at any vantage.
  # See knowledge/requirements_graph, "Writers and readers".
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

  # The generators one side at a time, for `Edges`. `compute_edges/3` draws the
  # union at once; the two must agree (`edges_derived_per_entity_match_the_pass_test`).

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
  edges and the cross-context edges its dependencies declare.
  """
  @spec component_side_edges(map(), map()) :: [edge()]
  def component_side_edges(ctx, config),
    do: component_template_edges(ctx, config) ++ cross_context_dependency_edges(ctx, config)

  @doc """
  One story's edges as generated: its own chain, its kickoff into the
  components, the exits back from them, and the pair joining it to the project.
  """
  @spec story_side_edges(map(), map(), map()) :: [edge()]
  def story_side_edges(story, ctx, config) do
    timing = %{closure: 0, expand: 0, kickoff: 0, exit: 0, components: 0}
    {chain, _timing} = story_chain_edges(story, ctx, config, timing)
    one = %{stories: [story]}

    story_template_edges(story, ctx, config) ++
      chain ++ project_to_story_edges(one) ++ story_to_project_edges(one)
  end

  @doc """
  The project's own chain as generated.
  """
  @spec project_side_edges(Scope.t(), map()) :: [edge()]
  def project_side_edges(scope, config), do: project_template_edges(scope, config)

  # The project's own chain, node-free like the other two.
  defp project_template_edges(scope, config) do
    project = scope.active_project
    template = maybe_filter_devops(RequirementDefinitionData.project_graph(), config)
    id_map = Map.new(template, fn d -> {d.id, [{"project", project.id, d.name}]} end)

    build_template_edges(template, id_map)
  end

  # A component and its parent recompute together, or not at all: a template
  # runs per family, and a child narrowed alone reads as top-level and runs a
  # different template. Over-grouping costs a little and cannot be wrong.
  # See knowledge/requirements_graph, "Marks and drains".
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

  # A template owner that is itself a child of another context runs under that
  # context's template, so the containing context comes along, recursively.
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

  The incremental graph's unit of work: the work one entity earned and no more.
  `reduce_to/2` narrows the lists and leaves the by-id maps whole, so an entity
  computed alone answers identically to the same entity computed in a larger set.

  Returns `{covered, nodes}`: for a component the unit is its family (see
  `expand_component_families/2`), not itself. Project nodes take the whole
  context, since their checkers read counts across the project.
  See knowledge/requirements_graph, "Marks and drains".
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

  # Answers with the project's real id: a mark naming the project carries none,
  # and `{"project", nil}` would reach `GraphStore.write/3` as a nil project_id.
  def compute_entity(scope, ctx, config, {"project", _id}) do
    {nodes, _} = compute_project_nodes(scope, ctx, config)
    {MapSet.new([{"project", scope.active_project.id}]), nodes}
  end

  @doc """
  The project's whole node set and the edges between them, computed and not
  written.

  Edges depend on the node set, never on a verdict: only a drain that wrote or
  reaped nodes needs this. See knowledge/requirements_graph, "Edges".
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

  On its own so a caller settling several vantages can draw the edges once:
  every vantage shares the shape.
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

  @doc """
  The graph as the rows hold it, after settling the writer.

  Returns `{{nodes, edges}, computed_at}`: `computed_at` is the latest row's
  `checked_at`, or `nil` when this vantage has no rows. Reads compute nothing.
  """
  @spec cached_graph(Scope.t(), keyword()) ::
          {{[Requirement.t()], [edge()]}, DateTime.t() | nil}
  def cached_graph(%Scope{} = scope, opts \\ []) do
    if Keyword.get(opts, :settle, true), do: settle(scope)

    {nodes, edges} = served_graph(scope, read_context(scope))
    {{nodes, edges}, last_checked_at(nodes)}
  end

  @doc """
  What a read needs at the scope's vantage: `Preloader.read_context/1`, never
  the computation's `Preloader.load/1`. See knowledge/requirements_graph,
  "The read path".
  """
  @spec read_context(Scope.t()) :: map()
  def read_context(%Scope{} = scope),
    do: scope |> normalize_vantage() |> Preloader.read_context()

  @doc """
  For a reader that already holds `read_context/1`'s context, so one read loads
  it once. Settles, loads and ranks nothing: the caller settled first.
  """
  @spec served_graph(Scope.t(), map()) :: {[Requirement.t()], [edge()]}
  def served_graph(%Scope{} = scope, ctx),
    do: scope |> normalize_vantage() |> Projection.load(ctx)

  @doc """
  `cached_graph/1` plus the actionable set, for readers that want both without
  paying for the read context twice.

  Returns `{{nodes, edges}, actionable, computed_at}`.

  ## Options

    * `:settle` — reconcile the watcher's queue before answering. Defaults to
      `true`, and every production reader wants the default.

  A read waits for observations already pending; it never re-derives what
  nobody announced. `settle: false` answers from the rows as they stand, for the
  test that must see a write that announced nothing still missing.
  See knowledge/requirements_graph, "Writers and readers".
  """
  @spec cached_graph_with_actionable(Scope.t(), keyword()) ::
          {{[Requirement.t()], [edge()]}, [Requirement.t()], DateTime.t() | nil}
  def cached_graph_with_actionable(%Scope{} = scope, opts \\ []) do
    scope = normalize_vantage(scope)

    if Keyword.get(opts, :settle, true) do
      settle_owner(scope)
    end

    serve_with_actionable(scope, Preloader.read_context(scope))
  end

  @doc """
  The same, with what a reader needs to say where the answer came from.

  For the requirements graph page. `served_from` is `"cache"` when rows
  answered this read and `"empty"` when this vantage has none — never
  "computed": reads compute nothing, and on a page that says whether the graph
  is current that word must not mislead.
  """
  @spec cached_graph_with_actionable_metrics(Scope.t()) :: {map(), map()}
  def cached_graph_with_actionable_metrics(%Scope{} = scope) do
    scope = normalize_vantage(scope)

    # Settle, like every other read, or the page renders a graph one write behind.
    settle_owner(scope)

    {us_preload, ctx} = :timer.tc(fn -> Preloader.read_context(scope) end)

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

    {%{nodes: nodes, edges: edges, actionable: actionable, components: ctx.components}, metrics}
  end

  # A read answers from the rows; it never re-derives what nobody announced, or
  # a writer that announces nothing would look like one that works. Freshness
  # is per row (`checked_at`). See knowledge/requirements_graph, "Lessons".
  defp serve_with_actionable(scope, ctx) do
    {nodes, edges} = Projection.load(scope, ctx)

    # `Preloader.read_context/1` is enough: `Projection.load/2` reads the shape
    # and `actionable_from/3` reads `ctx.components_by_id` and `ctx.stories`.
    {{nodes, edges}, actionable_from(nodes, edges, ctx), last_checked_at(nodes)}
  end

  @doc """
  What is served, against every entity recomputed from its inputs now.

  The incremental graph's audit: recomputed from the domain this minute, does
  every requirement and edge agree with what is served? Nothing is written.
  Expensive on purpose — one whole computation, on demand.
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

  # A reader that named only the project id (the dev page) carries neither the
  # project nor its account, and both are read: the project chain from
  # `active_project`, the checkers through the account.
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

  What `GraphStore.definitions_covered?/2` compares a vantage's rows against:
  handlers settle rows and never create them, so a release that changes the
  definitions needs a reseed. Child-scoped definitions are left out because
  they depend on the child's type. See knowledge/requirements_graph, "Seeding".
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

  # When the rows were last computed, taken from the rows: freshness is per row.
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

  `actionable_from/3` blocks a node behind *any* unsatisfied prerequisite. Here
  a block travels only where it means something to the role asking, so another
  role's queue (an untriaged issue backlog, say) cannot hide this role's work:

    * **Same entity** — a story's own chain clamps regardless of role.
      `three_amigos_complete` is product's and `bdd_specs_exist` is coding's, and
      specs for a story genuinely wait on that story's Three Amigos.
    * **Same role** — a role's own unfinished work still orders itself, across
      entities as before.

  A prerequisite that is neither orders the work and does not clamp it.
  `actionable_from/3`'s other conditions still apply.

  `seeds` is which unsatisfied nodes clamp: `:all`, or `:local` (story and
  component nodes only — the view of an agent bound to its active story, which
  is never offered project work and so is not held behind it).
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
    * `:local` — all but project-level ones.
    * `{:story, story_id, component_ids}` — only the bound story's own nodes
      and its member components' (`story_component_ids/2`), so another story's
      unmet prerequisite reached through a kickoff edge cannot hold a bound agent.
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

  # Satisfaction is local: each node's `satisfied` is its own leaf check, never
  # mutated by graph context. Upstream gating happens in `actionable_from`.

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

    {dedup_us, unique} = :timer.tc(fn -> Enum.uniq(kept) end)

    log_edge_timing(generated, unique, generate_us, filter_us + dedup_us)
    log_edge_sources(by_source)

    unique
  end

  # Per-source counts and duplicates, so the generator wasting work is visible.
  # See knowledge/requirements_graph, "Edges".
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

  # Duplicate multiplicity: ×2 means two paths to one edge; a long tail means
  # many stories re-emitting one shared closure. They want different fixes.
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

  defp log_edge_timing(generated, kept, generate_us, filter_us) do
    ms = &round(&1 / 1000)

    Logger.info(
      "[Requirements] edges — #{length(generated)} generated, #{length(kept)} unique; " <>
        "generate #{ms.(generate_us)}ms, filter+dedup #{ms.(filter_us)}ms"
    )
  end

  # Cross-entity: story ↔ surface tree. Kickoff edges (`bdd_specs_exist → first
  # work item`) span the surface and its transitive cross-context dependency
  # closure, one edge per kickoff target.
  # Kickoff targets child implementations for contexts, or the component's own
  # implementation when it has no implementable children; a live context exits
  # through its children's implementations. `children_by_parent` is built once
  # here rather than per story.
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

  # The component tree's four costs split apart (closure, expand, kickoff,
  # exit); `components` is the total kickoff fan-out across stories.
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

  @doc "The story requirement a component's finished work feeds."
  def component_join, do: @component_join

  @doc "The project requirement a story's finished QA feeds."
  def story_join, do: @story_join

  @doc """
  A story's subgraph: its surface, the surface's descendants, and everything
  those depend on, transitively. The one set of a story's components — kickoff
  gating, priority within a story, what a bound team is offered, and what holds
  it.

  A dependency context brings its direct children, since a context is
  implemented through them; nothing recurses further, or one story's set
  swallows half the project.
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
    end
  end

  # A context is implemented through its children (its kickoff targets them),
  # so depending on one is depending on its direct children too. Direct only,
  # and not their dependencies.
  @containers ~w(context live_context)

  defp context_children(%{type: type, id: id}, children_by_parent) when type in @containers,
    do: Map.get(children_by_parent, id, [])

  defp context_children(_component, _children_by_parent), do: []

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

  # A child in the kickoff closure that lands on its own node already emits this
  # edge, so the parent's fan-out to it would be a duplicate. Both conditions are
  # load-bearing: otherwise the parent's edge is the only one.
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
  #   child's terminal feeds ready_for_qa.
  #
  # The gate then feeds qa_complete via the intra-story prerequisite
  # edge, so a story cannot reach QA before its own specs have gone green.
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
            to: {"story", story.id, @component_join}
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
              to: {"story", story.id, @component_join}
            }
          ]
      end
    end)
  end

  defp direct_children(parent, ctx), do: Map.get(ctx.children_by_parent, parent.id, [])

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

  # `first_filtered_def/2` keyed by type, computed once per graph: a pure
  # function of `(type, config)` that was the hot spot of kickoff generation.
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
  # The project-level fan-in: every story's QA completion gates the project's QA
  # journey chain. `GraphProjector` lays out on this seam, so keep a
  # story→project fan-in even if the target node changes.
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
          to: {"project", project_id, @story_join}
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
  # Transitive, so a reopened project-chain requirement hides component work
  # even though every locally-satisfied node between them reports satisfied.
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
    # Stamped here, where the entity is hashed; idempotent if the caller did too.
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

  # Who runs a template, and for whom. Only context-shaped types (templates with
  # :child defs) own their nested components. A component nested under a
  # non-context parent is still top-level and runs its own template, or
  # everything below an umbrella drops out of the graph. The one copy of this
  # split: `defined_names/2` and the family closure use it too.
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

  # Stamped after the fact: a container's template emits its children's nodes,
  # and each carries its own entity's fingerprint wherever it was produced.
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
    # Stamped here, where the entity is hashed; idempotent if the caller did too.
    ctx = Freshness.with_config(ctx, config)

    # Only the devops filter applies to story templates: devops: :off drops the
    # deploy requirement from every story.
    template = maybe_filter_devops(RequirementDefinitionData.story_graph(), config)
    project = scope.active_project

    {nodes, edges} =
      Enum.flat_map_reduce(ctx.stories, [], fn story, all_edges ->
        files = Map.get(ctx.files_by_story, story.id, [])

        # Once per story: its requirements read the same slice of the context.
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

  # `nil` when the context was loaded narrow: a fingerprint of a narrow context
  # looks comparable to a whole one and is not. `nil` reads as "no basis to skip".
  defp story_fingerprint(%{skip_fingerprints: true}, _story), do: nil
  defp story_fingerprint(ctx, story), do: Freshness.story(ctx, story)

  defp compute_project_nodes(scope, ctx, config) do
    project = scope.active_project

    # Only the devops filter applies to the project template, as for stories.
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
          # Stamped like every other entity.
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
  # The late set is hardcoded, not derived from the edges: moving a requirement's
  # prerequisites changes what it blocks, not where it sorts, so a requirement
  # that moves to gate the journey must be added here too.
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
  # already under way outranks one nobody has started at the same priority: one
  # story at a time, specs then code then QA. See knowledge/requirements_graph, "Lessons".
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

  # A story's rank: its priority, then its age, so the older of two stories at
  # one priority leads and `min/2` over the pair is deterministic.
  defp story_rank(story) do
    {story.priority || 999, story_age(story)}
  end

  defp story_age(%{inserted_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp story_age(%{inserted_at: %NaiveDateTime{} = at}),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp story_age(_story), do: 0

  # component_id → best (lowest) story rank, inherited from stories that link it,
  # stories whose surface depends on it, and parent components recursively. A
  # tree rooted at a context with no priority inherits nothing, and the
  # untethered filter drops it from the wave.
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

  # `devops: :off` is the default, so this filter keeps most projects' graphs
  # silent about infrastructure: deployment requirements are absent, not
  # present-and-skipped, since a greyed-out step still reads as part of the run.
  defp maybe_filter_devops(definitions, config) do
    case ProjectConfiguration.devops_level(config) do
      :off -> Enum.reject(definitions, &(&1.artifact_type == :deployment))
      _on -> definitions
    end
  end
end
