defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph — nodes AND edges — from Files + Problems.

  The graph is entity-agnostic: edges represent real dependencies regardless of
  whether they cross entity boundaries. There are three kinds of edges:

  1. **Same-entity prerequisites**: spec_file → spec_valid (within a component)
  2. **Project → story**: project.qa_setup → story.component_linked (the
     whole-project gate that opens story-level work)
  2. **Story → component tree**: bdd_specs_exist → component's first req;
     component's terminal req → bdd_specs_passing
  3. **Stories → project**: each story's qa_complete → all_bdd_specs_passing
     (project-level fan-in node — gives the requirements graph a structural
     seam where story state aggregates into project state, which the
     graph projector uses to lay out late_project nodes at the bottom band)
  """

  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Requirements.Preloader
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
  @spec compute_graph(Scope.t()) :: {[Requirement.t()], [edge()]}
  def compute_graph(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {nodes, ctx} = compute_all_from_ctx(scope, ctx, config)
    edges = compute_edges(nodes, ctx, config)
    {nodes, edges}
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
    ctx = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {nodes, ctx} = compute_all_from_ctx(scope, ctx, config)
    edges = compute_edges(nodes, ctx, config)
    actionable_from(nodes, edges, ctx)
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
    {us_preload, ctx} = :timer.tc(fn -> Preloader.load(scope) end)
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
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {nodes, _ctx} = compute_all_from_ctx(scope, ctx, config)
    nodes
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

    (template_edges ++
       project_to_story_edges(ctx) ++
       component_tree_edges(ctx, config) ++
       cross_context_dependency_edges(ctx, config) ++
       story_to_project_edges(ctx))
    |> Enum.filter(fn %{from: f, to: t} ->
      MapSet.member?(node_keys, f) and MapSet.member?(node_keys, t)
    end)
    |> Topology.transitive_reduction()
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
  defp component_tree_edges(ctx, config) do
    ctx.stories
    |> Enum.filter(&(&1.component_id != nil))
    |> Enum.flat_map(&story_chain_edges(&1, ctx, config))
  end

  defp story_chain_edges(story, ctx, config) do
    case Enum.find(ctx.components, &(&1.id == story.component_id)) do
      nil ->
        []

      surface ->
        kickoff_components =
          surface
          |> transitive_dep_closure(ctx)
          |> expand_with_parent_chain_descendants(ctx)

        kickoff_edges = Enum.flat_map(kickoff_components, &kickoff_edge(&1, story, config, ctx))
        kickoff_edges ++ surface_exit_edge(surface, story, ctx, config)
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
    children_by_parent =
      ctx.components
      |> Enum.filter(& &1.parent_component_id)
      |> Enum.group_by(& &1.parent_component_id)

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

  defp kickoff_edge(comp, story, config, ctx) do
    case first_filtered_def(comp.type, config) do
      nil ->
        []

      %{node_scope: :child, name: name} ->
        comp
        |> direct_children(ctx)
        |> Enum.filter(&child_supports_def_name?(&1, name))
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

  defp child_supports_def_name?(child, name) do
    child.type
    |> ComponentRegistry.get_requirements_for_type()
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
  defp surface_exit_edge(surface, story, ctx, config) do
    if ComponentRegistry.has_children?(surface.type) do
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
    Enum.filter(ctx.components, &(&1.parent_component_id == parent.id))
  end

  defp child_terminal_name(parent_type, child_type, config) do
    child_own_names =
      child_type
      |> ComponentRegistry.get_requirements_for_type()
      |> MapSet.new(& &1.name)

    parent_type
    |> ComponentRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> Enum.filter(&(&1.node_scope == :child and &1.name in child_own_names))
    |> List.last()
    |> case do
      nil -> nil
      def -> def.name
    end
  end

  defp first_filtered_def(type, config) do
    type
    |> ComponentRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.first()
  end

  defp last_filtered_def(type, config) do
    type
    |> ComponentRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.last()
  end

  defp transitive_dep_closure(start_component, ctx) do
    [start_component.id]
    |> bfs_dep_ids(MapSet.new(), ctx)
    |> Enum.map(fn id -> Enum.find(ctx.components, &(&1.id == id)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp bfs_dep_ids([], visited, _ctx), do: visited

  defp bfs_dep_ids([id | rest], visited, ctx) do
    if MapSet.member?(visited, id) do
      bfs_dep_ids(rest, visited, ctx)
    else
      visited = MapSet.put(visited, id)

      new_dep_ids =
        case Enum.find(ctx.components, &(&1.id == id)) do
          nil -> []
          comp -> comp |> component_deps() |> Enum.map(& &1.id)
        end

      bfs_dep_ids(rest ++ new_dep_ids, visited, ctx)
    end
  end

  defp find_def(definitions, name) do
    Enum.find(definitions, &(&1.name == name))
  end

  # Cross-entity: story.qa_complete → project.all_bdd_specs_passing.
  # The project-level fan-in: every story's QA completion gates the
  # project's `all_bdd_specs_passing` aggregate, which downstream
  # nodes (qa_journey_plan etc.) depend on. Restoring this edge after
  # the e7452b3a / 36ae631e removal so the graph projector has a
  # structural seam to lay late_project nodes against the bottom band.
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
          to: {"project", project_id, "all_bdd_specs_passing"}
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
    with %_{} = dep_comp <- Enum.find(ctx.components, &(&1.id == dep.id)),
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
    |> ComponentRegistry.get_requirements_for_type()
    |> filter_definitions_by_config(config)
    |> List.last()
  end

  defp cross_context_target(comp, dep_comp, config) do
    comp_defs =
      comp.type
      |> ComponentRegistry.get_requirements_for_type()
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
      |> Enum.filter(&ComponentRegistry.has_children?(&1.type))
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
          instantiate_template(scope, ctx, filtered_template, original_template, component, children)
        end)

      log_slow_component(component, children, nodes, us)

      {nodes, all_edges ++ edges}
    end)
  end

  @slow_component_threshold_us 50_000

  defp log_slow_component(component, children, nodes, us) when us >= @slow_component_threshold_us do
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
      subagent_role: definition.subagent_role,
      parent_entity_id: parent_id,
      parent_entity_name: parent_name,
      prerequisites: [],
      details: result.details
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

        nodes = Enum.map(template, fn definition ->
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
            subagent_role: definition.subagent_role,
            parent_entity_id: project && project.id,
            parent_entity_name: project && project.name,
            prerequisites: [],
            details: result.details
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

    nodes = Enum.map(template, fn definition ->
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
        subagent_role: definition.subagent_role,
        prerequisites: [],
        details: result.details
      }
    end)

    edges = build_template_edges(template, id_map)
    {nodes, edges}
  end

  # -- Sorting --
  # Actionable nodes sorted by (priority, link_rank).
  # link_rank breaks ties so story-linked components always sort
  # before orphan components, and project-level requirements sort
  # after both. The graph edges already encode within-chain
  # execution order.
  defp sort_by_story_priority(nodes, ctx) do
    story_by_id = Map.new(ctx.stories, &{&1.id, &1})
    component_priority = build_component_priority_map(ctx)
    Enum.sort_by(nodes, &priority_sort_key(&1, story_by_id, component_priority))
  end

  defp priority_sort_key(%{entity_type: "story", entity_id: id}, story_by_id, _comp_priority) do
    story = Map.get(story_by_id, id)
    {(story && story.priority) || 999, 0}
  end

  defp priority_sort_key(%{entity_type: "component", entity_id: id}, _story_by_id, comp_priority) do
    case Map.fetch(comp_priority, id) do
      {:ok, priority} -> {priority, 0}
      :error -> {999, 1}
    end
  end

  defp priority_sort_key(%{entity_type: "project"}, _story_by_id, _comp_priority), do: {999, 2}

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
        surface = Enum.find(ctx.components, &(&1.id == story.component_id))
        priority = story.priority || 999

        deps = case surface && surface.dependencies do
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
  # devops: :off → removes devops_setup + deploy (the graph stays silent
  # about infrastructure; the user deploys on their own terms)
  defp filter_definitions_by_config(definitions, config) do
    definitions
    |> maybe_filter_specs(config)
    |> maybe_filter_reviews(config)
    |> maybe_filter_tests(config)
    |> maybe_filter_devops(config)
  end

  defp maybe_filter_devops(definitions, %{devops: :off}) do
    Enum.reject(definitions, &(&1.name in ["devops_setup", "deploy"]))
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
