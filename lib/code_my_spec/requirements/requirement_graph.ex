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

  alias CodeMySpec.Components.Component
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
    {nodes, ctx} = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx, scope.active_project)
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
    {nodes, ctx} = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx, scope.active_project)
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
    {nodes, ctx} = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx, scope.active_project)
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
      Enum.map_reduce(nodes, false, fn node, any_changed ->
        if node.satisfied do
          sources = Map.get(incoming, node_key(node), [])

          any_unsatisfied =
            Enum.any?(sources, fn source_key ->
              Map.get(satisfaction_map, source_key, true) == false
            end)

          if any_unsatisfied do
            {%{node | satisfied: false, details: Map.put(node.details || %{}, :reason, "prerequisites not yet satisfied")}, true}
          else
            {node, any_changed}
          end
        else
          {node, any_changed}
        end
      end)

    if changed?, do: do_clamp(updated_nodes, incoming), else: updated_nodes
  end

  # -- Edge computation --

  defp compute_edges(_nodes, ctx, project) do
    # Template edges are computed during instantiation (stored in ctx)
    template_edges = ctx[:template_edges] || []

    template_edges ++
      project_to_story_edges(ctx) ++
      component_tree_edges(ctx, project) ++
      cross_context_dependency_edges(ctx, project) ++
      story_to_project_edges(ctx)
  end

  # Cross-entity: story ↔ surface component + its direct context dependencies.
  # Gives fan-out: story → surface + each context dep → back to story.
  # Context trees are internally connected via context_container_edges.
  defp component_tree_edges(ctx, project) do
    ctx.stories
    |> Enum.filter(&(&1.component_id != nil))
    |> Enum.flat_map(fn story ->
      surface = Enum.find(ctx.components, &(&1.id == story.component_id))

      if surface do
        # Surface component edges
        surface_edges = edges_for_component(surface, story, project)

        # Direct dependency edges (contexts the surface depends on)
        dep_edges =
          case surface.dependencies do
            %Ecto.Association.NotLoaded{} -> []
            deps when is_list(deps) ->
              Enum.flat_map(deps, fn dep ->
                dep_comp = Enum.find(ctx.components, &(&1.id == dep.id))
                if dep_comp, do: edges_for_component(dep_comp, story, project), else: []
              end)
          end

        surface_edges ++ dep_edges
      else
        []
      end
    end)
  end

  defp edges_for_component(comp, story, project) do
    defs =
      ComponentRegistry.get_requirements_for_type(comp.type)
      |> filter_definitions_by_project_settings(project)

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
  defp cross_context_dependency_edges(ctx, project) do
    ctx.components
    |> Enum.flat_map(fn comp ->
      deps = case comp.dependencies do
        %Ecto.Association.NotLoaded{} -> []
        deps when is_list(deps) -> deps
        _ -> []
      end

      Enum.flat_map(deps, fn dep ->
        dep_comp = Enum.find(ctx.components, &(&1.id == dep.id))

        if dep_comp do
          dep_defs =
            ComponentRegistry.get_requirements_for_type(dep_comp.type)
            |> filter_definitions_by_project_settings(project)

          comp_defs =
            ComponentRegistry.get_requirements_for_type(comp.type)
            |> filter_definitions_by_project_settings(project)

          dep_terminal = List.last(dep_defs)
          siblings? = comp.parent_component_id != nil and
                      comp.parent_component_id == dep_comp.parent_component_id

          # Siblings: gate implementation only. Cross-context: gate everything.
          target =
            if siblings? do
              find_def(comp_defs, "implementation_file")
            else
              List.first(comp_defs)
            end

          # Skip cross-context edges for child components — parent_child_edges
          # propagates ordering from the parent context to its children.
          skip? = not siblings? and comp.parent_component_id != nil

          if dep_terminal && target && not skip? do
            [%{from: {"component", dep_comp.id, dep_terminal.name},
               to: {"component", comp.id, target.name}}]
          else
            []
          end
        else
          []
        end
      end)
    end)
  end

  # Cross-entity: project.issues_resolved → story.component_linked
  defp project_to_story_edges(ctx) do
    project_id = ctx.stories |> List.first() |> then(fn s -> s && s.project_id end)

    if project_id && ctx.stories != [] do
      Enum.map(ctx.stories, fn story ->
        %{from: {"project", project_id, "issues_resolved"}, to: {"story", story.id, "component_linked"}}
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

  defp compute_all_from_ctx(scope, ctx) do
    {component_nodes, component_edges} = instantiate_component_graphs(scope, ctx)
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
  defp instantiate_component_graphs(scope, ctx) do
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
      template = RequirementDefinitionData.graph_for_type(component.type)

      {nodes, edges} = instantiate_template(scope, ctx, template, component, children)
      {nodes, all_edges ++ edges}
    end)
  end

  # Instantiate a single graph template for a component + its children.
  defp instantiate_template(scope, ctx, template, component, children) do
    parent_defs = Enum.filter(template, &(&1.node_scope == :parent))
    child_defs = Enum.filter(template, &(&1.node_scope == :child))
    self_defs = Enum.filter(template, &(&1.node_scope == :self))

    # Build ID → node_key map for edge resolution
    id_map = build_id_map(template, component, children)

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

    # Build edges from template prerequisites
    edges = build_template_edges(template, id_map)

    {all_nodes, edges}
  end

  # Map template IDs to real node keys.
  # :parent and :self nodes map to the component itself.
  # :child nodes map to EACH child — one key per child per template ID.
  defp build_id_map(template, component, children) do
    Enum.flat_map(template, fn def ->
      case def.node_scope do
        :parent ->
          [{def.id, [{"component", component.id, def.name}]}]

        :self ->
          [{def.id, [{"component", component.id, def.name}]}]

        :child ->
          keys = Enum.map(children, fn child ->
            {"component", child.id, def.name}
          end)
          [{def.id, keys}]
      end
    end)
    |> Map.new()
  end

  # Build edges by resolving template prerequisite IDs to real node keys.
  #
  # Edge semantics depend on the node_scope of source and target:
  # - child → child (same scope): zip by child (each child's node depends on its OWN prereq)
  # - parent → child: fan-out (one parent node → each child's node)
  # - child → parent: fan-in (each child's node → one parent node)
  # - same scope single: direct edge
  defp build_template_edges(template, id_map) do
    scope_by_id = Map.new(template, &{&1.id, &1.node_scope})

    Enum.flat_map(template, fn def ->
      to_keys = Map.get(id_map, def.id, [])

      Enum.flat_map(def.prerequisites, fn prereq_id ->
        from_keys = Map.get(id_map, prereq_id, [])
        from_scope = Map.get(scope_by_id, prereq_id)
        to_scope = def.node_scope

        build_edges_for_scopes(from_scope, to_scope, from_keys, to_keys)
      end)
    end)
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
      parent_entity_id: parent && parent.id,
      parent_entity_name: parent && parent.module_name,
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
    id_to_name = Map.new(template, &{&1.id, &1.name})

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

  # -- Helpers --

  # Walk hierarchical children AND dependencies to collect all component IDs
  # that must be satisfied for a story's component tree.
  defp collect_all_component_ids(component_id, components, visited) do
    if MapSet.member?(visited, component_id) do
      []
    else
      visited = MapSet.put(visited, component_id)
      comp = Enum.find(components, &(&1.id == component_id))

      if comp do
        # Hierarchical children
        children = Enum.filter(components, &(&1.parent_component_id == component_id))
        child_ids = Enum.flat_map(children, &collect_all_component_ids(&1.id, components, visited))

        # Dependencies
        deps = case comp.dependencies do
          %Ecto.Association.NotLoaded{} -> []
          deps when is_list(deps) -> deps
        end
        dep_ids = Enum.flat_map(deps, &collect_all_component_ids(&1.id, components, visited))

        [component_id | child_ids ++ dep_ids] |> Enum.uniq()
      else
        []
      end
    end
  end


  # -- Sorting --
  # Actionable nodes sorted by story priority only.
  # The graph edges already encode execution order.
  defp sort_by_story_priority(nodes, ctx) do
    story_by_id = Map.new(ctx.stories, &{&1.id, &1})
    component_priority = build_component_priority_map(ctx)

    Enum.sort_by(nodes, fn node ->
      case node.entity_type do
        "story" ->
          (story_by_id[node.entity_id] && story_by_id[node.entity_id].priority) || 999

        "component" ->
          Map.get(component_priority, node.entity_id, 999)

        "project" ->
          999
      end
    end)
  end

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
    case Map.get(acc, component_id) do
      nil ->
        parent_id = Map.get(parent_map, component_id)
        if parent_id do
          acc = find_priority_from_parent(parent_id, parent_map, acc)
          case Map.get(acc, parent_id) do
            nil -> acc
            priority -> Map.put(acc, component_id, priority)
          end
        else
          acc
        end

      _priority ->
        acc
    end
  end

  # -- Fast mode filtering --

  # Filters component requirement definitions based on project settings.
  # require_specs: false → removes :specification and :review artifact types
  # require_unit_tests: false → removes :tests artifact type + tests_passing
  defp filter_definitions_by_project_settings(definitions, project) do
    definitions
    |> maybe_filter_specs(project)
    |> maybe_filter_tests(project)
  end

  defp maybe_filter_specs(definitions, %{require_specs: false}) do
    Enum.reject(definitions, &(&1.artifact_type in [:specification, :review]))
  end

  defp maybe_filter_specs(definitions, _project), do: definitions

  defp maybe_filter_tests(definitions, %{require_unit_tests: false}) do
    Enum.reject(definitions, fn def ->
      def.artifact_type == :tests or def.name == "tests_passing"
    end)
  end

  defp maybe_filter_tests(definitions, _project), do: definitions
end
