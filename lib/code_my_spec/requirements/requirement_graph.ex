defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph — nodes AND edges — from Files + Problems.

  The graph is entity-agnostic: edges represent real dependencies regardless of
  whether they cross entity boundaries. There are three kinds of edges:

  1. **Same-entity prerequisites**: spec_file → spec_valid (within a component)
  2. **Story → component tree**: bdd_specs_exist → component's first req;
     component's terminal req → bdd_specs_passing
  3. **Stories → project**: each story's qa_complete → qa_preflight
  """

  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
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
    nodes = clamp_satisfaction(nodes, edges)
    {nodes, edges}
  end

  @doc """
  Returns the next actionable requirements — unsatisfied nodes where
  every incoming edge is satisfied.
  """
  @spec next_actionable(Scope.t()) :: [Requirement.t()]
  def next_actionable(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {nodes, ctx} = compute_all_from_ctx(scope, ctx, config)
    edges = compute_edges(nodes, ctx, config)
    nodes = clamp_satisfaction(nodes, edges)

    satisfaction_map =
      Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    incoming =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.to, [edge.from], &[edge.from | &1])
      end)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        incoming_prereqs_satisfied?(n, incoming, satisfaction_map)
    end)
    |> sort_by_story_priority(ctx)
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    config = CodeMySpec.Configurations.get_or_create(scope)
    {nodes, ctx} = compute_all_from_ctx(scope, ctx, config)
    edges = compute_edges(nodes, ctx, config)
    clamp_satisfaction(nodes, edges)
  end

  # -- Satisfaction clamping --
  # A node cannot be satisfied if any of its incoming edge sources are unsatisfied.
  # This prevents vacuous truth (e.g. "zero problems" when nothing has been built).
  # Iterates until stable since clamping one node may cascade to its dependents.
  defp clamp_satisfaction(nodes, edges) do
    incoming =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.to, [edge.from], &[edge.from | &1])
      end)

    do_clamp(nodes, incoming)
  end

  defp do_clamp(nodes, incoming) do
    satisfaction_map = Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    {updated_nodes, changed?} =
      Enum.map_reduce(nodes, false, &maybe_unsatisfy_node(&1, &2, incoming, satisfaction_map))

    if changed?, do: do_clamp(updated_nodes, incoming), else: updated_nodes
  end

  defp maybe_unsatisfy_node(node, any_changed, _incoming, _satisfaction_map)
       when not node.satisfied,
       do: {node, any_changed}

  defp maybe_unsatisfy_node(node, any_changed, incoming, satisfaction_map) do
    sources = Map.get(incoming, node_key(node), [])

    if any_unsatisfied?(sources, satisfaction_map),
      do: {unsatisfy(node), true},
      else: {node, any_changed}
  end

  defp any_unsatisfied?(sources, satisfaction_map) do
    Enum.any?(sources, fn source_key ->
      Map.get(satisfaction_map, source_key, true) == false
    end)
  end

  defp unsatisfy(node) do
    %{
      node
      | satisfied: false,
        details: Map.put(node.details || %{}, :reason, "prerequisites not yet satisfied")
    }
  end

  # -- Edge computation --

  defp compute_edges(_nodes, ctx, config) do
    # Template edges are computed during instantiation (stored in ctx)
    template_edges = ctx[:template_edges] || []

    template_edges ++
      project_to_story_edges(ctx) ++
      component_tree_edges(ctx, config) ++
      cross_context_dependency_edges(ctx, config) ++
      story_to_project_edges(ctx)
  end

  # Cross-entity: story ↔ surface component only.
  # The story's terminal requirement depends on the surface's terminal
  # requirement; context dependencies reach the story transitively
  # through the surface via cross_context_dependency_edges. This is
  # rule 3 of story 562: the chain flows through the surface, not as
  # direct prerequisites of the story.
  defp component_tree_edges(ctx, config) do
    ctx.stories
    |> Enum.filter(&(&1.component_id != nil))
    |> Enum.flat_map(&edges_for_story_surface(&1, ctx, config))
  end

  defp edges_for_story_surface(story, ctx, config) do
    case Enum.find(ctx.components, &(&1.id == story.component_id)) do
      nil -> []
      surface -> edges_for_component(surface, story, config)
    end
  end

  defp edges_for_component(comp, story, config) do
    defs =
      ComponentRegistry.get_requirements_for_type(comp.type)
      |> filter_definitions_by_config(config)

    first = List.first(defs)
    terminal = List.last(defs)

    entry =
      if first,
        do: [%{from: {"story", story.id, "bdd_specs_exist"}, to: {"component", comp.id, first.name}}],
        else: []

    exit =
      if terminal,
        do: [%{from: {"component", comp.id, terminal.name}, to: {"story", story.id, "bdd_specs_passing"}}],
        else: []

    entry ++ exit
  end

  defp find_def(definitions, name) do
    Enum.find(definitions, &(&1.name == name))
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

  # Cross-entity: story.qa_complete → project.qa_preflight
  defp story_to_project_edges(ctx) do
    project_id = hd(ctx.stories ++ [nil]) && List.first(ctx.stories) && List.first(ctx.stories).project_id

    if project_id && ctx.stories != [] do
      Enum.map(ctx.stories, fn story ->
        %{from: {"story", story.id, "qa_complete"}, to: {"project", project_id, "qa_preflight"}}
      end)
    else
      []
    end
  end

  # -- Actionability --

  # A node is actionable when all its incoming edge sources are satisfied.
  defp incoming_prereqs_satisfied?(node, incoming, satisfaction_map) do
    sources = Map.get(incoming, node_key(node), [])

    Enum.all?(sources, fn source_key ->
      Map.get(satisfaction_map, source_key, true)
    end)
  end

  defp node_key(n), do: {n.entity_type, n.entity_id, n.name}

  # -- Node computation --

  defp compute_all_from_ctx(scope, ctx, config) do
    {component_nodes, component_edges} = instantiate_component_graphs(scope, ctx, config)
    {story_nodes, story_edges} = compute_story_nodes(scope, ctx)
    {project_nodes, project_edges} = compute_project_nodes(scope, ctx)

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
    # Build parent→children map
    children_by_parent =
      ctx.components
      |> Enum.filter(& &1.parent_component_id)
      |> Enum.group_by(& &1.parent_component_id)

    # Components that ARE children (handled by their parent's template)
    child_ids = ctx.components |> Enum.filter(& &1.parent_component_id) |> MapSet.new(& &1.id)

    ctx.components
    |> Enum.reject(fn c -> MapSet.member?(child_ids, c.id) end)
    |> Enum.flat_map_reduce([], fn component, all_edges ->
      children = Map.get(children_by_parent, component.id, [])

      original_template = RequirementDefinitionData.graph_for_type(component.type)
      filtered_template = filter_definitions_by_config(original_template, config)

      {nodes, edges} =
        instantiate_template(scope, ctx, filtered_template, original_template, component, children)

      {nodes, all_edges ++ edges}
    end)
  end

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

  defp compute_story_nodes(scope, ctx) do
    template = RequirementDefinitionData.story_graph()
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

  defp compute_project_nodes(scope, ctx) do
    project = scope.active_project
    template = RequirementDefinitionData.project_graph()
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
  # 3. Parent components (via parent_component_id chain)
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

    # Spread priority down parent_component_id chains
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
  defp filter_definitions_by_config(definitions, config) do
    definitions
    |> maybe_filter_specs(config)
    |> maybe_filter_reviews(config)
    |> maybe_filter_tests(config)
  end

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
