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
    nodes = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx)
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
    nodes = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx)
    nodes = clamp_satisfaction(nodes, edges)

    satisfaction_map =
      Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    incoming =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.to, [edge.from], &[edge.from | &1])
      end)

    # Children of contexts are driven by container tasks (context_specs,
    # context_implementation) — not independently actionable.
    driven_child_ids = driven_component_ids(ctx)

    # Build map of parent_id → whether container nodes (context_specs/context_implementation) are still active
    active_container_parents = active_container_parent_ids(nodes, ctx)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        not driven_by_active_container?(n, driven_child_ids, active_container_parents, ctx) and
        incoming_prereqs_satisfied?(n, incoming, satisfaction_map, driven_child_ids)
    end)
    |> sort_by_story_priority(ctx)
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    nodes = compute_all_from_ctx(scope, ctx)
    edges = compute_edges(nodes, ctx)
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

  defp compute_edges(nodes, ctx) do
    same_entity_edges(nodes) ++
      project_to_story_edges(ctx) ++
      component_tree_edges(nodes, ctx) ++
      context_container_edges(ctx) ++
      component_dependency_edges(ctx) ++
      story_to_project_edges(nodes, ctx)
  end

  # Same-entity prerequisite edges (e.g. spec_file → spec_valid within one component)
  defp same_entity_edges(nodes) do
    Enum.flat_map(nodes, fn node ->
      Enum.map(node.prerequisites, fn prereq_name ->
        %{
          from: {node.entity_type, node.entity_id, prereq_name},
          to: node_key(node)
        }
      end)
    end)
  end

  # Cross-entity: story ↔ surface component + its direct context dependencies.
  # Gives fan-out: story → surface + each context dep → back to story.
  # Context trees are internally connected via context_container_edges.
  defp component_tree_edges(_nodes, ctx) do
    ctx.stories
    |> Enum.filter(&(&1.component_id != nil))
    |> Enum.flat_map(fn story ->
      surface = Enum.find(ctx.components, &(&1.id == story.component_id))

      if surface do
        # Surface component edges
        surface_edges = edges_for_component(surface, story)

        # Direct dependency edges (contexts the surface depends on)
        dep_edges =
          case surface.dependencies do
            %Ecto.Association.NotLoaded{} -> []
            deps when is_list(deps) ->
              Enum.flat_map(deps, fn dep ->
                dep_comp = Enum.find(ctx.components, &(&1.id == dep.id))
                if dep_comp, do: edges_for_component(dep_comp, story), else: []
              end)
          end

        surface_edges ++ dep_edges
      else
        []
      end
    end)
  end

  defp edges_for_component(comp, story) do
    defs = ComponentRegistry.get_requirements_for_type(comp.type)
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

  # Cross-entity edges between parent components and children.
  # Data-driven: when a child's requirement has a prerequisite that exists
  # on the parent but NOT on the child itself, create a cross-entity
  # edge from parent.prereq → child.req.
  # Fan-in: child's terminal req → parent's implementation_file.
  # Applies to any component with children (contexts, live_contexts, live_views).
  defp context_container_edges(ctx) do
    parent_ids = ctx.components |> Enum.map(& &1.parent_component_id) |> MapSet.new() |> MapSet.delete(nil)

    ctx.components
    |> Enum.filter(fn c -> MapSet.member?(parent_ids, c.id) end)
    |> Enum.flat_map(fn context ->
      parent_defs = ComponentRegistry.get_requirements_for_type(context.type)
      parent_req_names = MapSet.new(parent_defs, & &1.name)
      children = Enum.filter(ctx.components, &(&1.parent_component_id == context.id))

      Enum.flat_map(children, fn child ->
        child_defs = ComponentRegistry.get_requirements_for_type(child.type)
        child_req_names = MapSet.new(child_defs, & &1.name)
        child_terminal = List.last(child_defs)

        # Fan-out: child prereqs that reference parent requirements
        fan_out =
          Enum.flat_map(child_defs, fn child_def ->
            Enum.flat_map(child_def.prerequisites, fn prereq_name ->
              if not MapSet.member?(child_req_names, prereq_name) and
                   MapSet.member?(parent_req_names, prereq_name) do
                [%{from: {"component", context.id, prereq_name},
                   to: {"component", child.id, child_def.name}}]
              else
                []
              end
            end)
          end)

        # Fan-in: child phases feed back into parent
        spec_terminal = Enum.find(child_defs, &(&1.name == "spec_valid"))

        spec_fan_in =
          if spec_terminal do
            [%{from: {"component", child.id, spec_terminal.name},
               to: {"component", context.id, "review_file"}}]
          else
            []
          end

        impl_fan_in =
          if child_terminal do
            [%{from: {"component", child.id, child_terminal.name},
               to: {"component", context.id, "implementation_file"}}]
          else
            []
          end

        fan_out ++ spec_fan_in ++ impl_fan_in
      end)
    end)
  end

  # Component dependency edges: dep.terminal → dependent.first_req.
  # Ensures dependencies are completed before the components that depend on them.
  defp component_dependency_edges(ctx) do
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
          dep_defs = ComponentRegistry.get_requirements_for_type(dep_comp.type)
          comp_defs = ComponentRegistry.get_requirements_for_type(comp.type)
          dep_terminal = List.last(dep_defs)
          comp_first = List.first(comp_defs)

          if dep_terminal && comp_first do
            [%{from: {"component", dep_comp.id, dep_terminal.name},
               to: {"component", comp.id, comp_first.name}}]
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
  defp story_to_project_edges(_nodes, ctx) do
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

  # For container nodes (scope: :children), ignore incoming edges from
  # driven children — those are fan-in edges that represent completion,
  # not prerequisites. The container is actionable based on its same-entity
  # prereqs; its evaluate/2 checks child completion.
  defp incoming_prereqs_satisfied?(node, incoming, satisfaction_map, driven_child_ids) do
    sources = Map.get(incoming, node_key(node), [])

    sources
    |> Enum.reject(fn {_type, source_id, _name} ->
      # Container nodes (scope: :children) ignore fan-in edges from their
      # driven children — those represent completion, not prerequisites.
      node.scope == :children and MapSet.member?(driven_child_ids, source_id)
    end)
    |> Enum.all?(fn source_key ->
      Map.get(satisfaction_map, source_key, true)
    end)
  end

  # Components whose parent has :children scope containers.
  # Matches any component with children, consistent with context_container_edges.
  defp driven_component_ids(ctx) do
    parent_ids =
      ctx.components
      |> Enum.map(& &1.parent_component_id)
      |> MapSet.new()
      |> MapSet.delete(nil)

    ctx.components
    |> Enum.filter(fn c ->
      c.parent_component_id && MapSet.member?(parent_ids, c.parent_component_id)
    end)
    |> MapSet.new(& &1.id)
  end

  # A child is only "driven" (suppressed from actionable) if its parent's
  # container node (context_specs or context_implementation) is still unsatisfied
  # and actionable — meaning the container task will handle it. If the container
  # is already satisfied, the child should surface independently.
  defp driven_by_active_container?(
         %{entity_type: "component", entity_id: id} = _node,
         driven_child_ids,
         active_parents,
         ctx
       ) do
    if MapSet.member?(driven_child_ids, id) do
      comp = Enum.find(ctx.components, &(&1.id == id))
      parent_id = comp && comp.parent_component_id
      parent_id && MapSet.member?(active_parents, parent_id)
    else
      false
    end
  end

  defp driven_by_active_container?(_, _, _, _), do: false

  # Parents whose container nodes (context_specs or context_implementation) are
  # still unsatisfied — meaning the container task should drive the children.
  defp active_container_parent_ids(nodes, _ctx) do
    nodes
    |> Enum.filter(fn n ->
      n.entity_type == "component" and
        n.name in ["context_specs", "context_implementation"] and
        not n.satisfied
    end)
    |> MapSet.new(& &1.entity_id)
  end

  defp node_key(n), do: {n.entity_type, n.entity_id, n.name}

  # -- Node computation --

  defp compute_all_from_ctx(scope, ctx) do
    component_nodes = compute_component_nodes(scope, ctx)
    story_nodes = compute_story_nodes(scope, ctx)
    project_nodes = compute_project_nodes(scope, ctx)

    project_nodes ++ story_nodes ++ component_nodes
  end

  defp compute_component_nodes(scope, ctx) do
    Enum.flat_map(ctx.components, fn component ->
      definitions = ComponentRegistry.get_requirements_for_type(component.type)
      files = Map.get(ctx.files_by_component, component.id, [])

      Enum.map(definitions, fn definition ->
        result = RequirementCalculator.compute_one(scope, component, definition, files, ctx)

        %Requirement{
          entity_type: "component",
          entity_id: component.id,
          entity_name: component.module_name,
          name: definition.name,
          description: definition.description,
          satisfied: result.satisfied,
          satisfied_by: definition.satisfied_by,
          scope: definition.scope || :local,
          execution_type: definition.execution_type || :main_agent,
          validation_type: definition.validation_type || :automatic,
          prerequisites: definition.prerequisites,
          details: result.details
        }
      end)
    end)
  end

  defp compute_story_nodes(scope, ctx) do
    definitions = RequirementDefinitionData.story_requirements()

    Enum.flat_map(ctx.stories, fn story ->
      files = Map.get(ctx.files_by_story, story.id, [])

      Enum.map(definitions, fn definition ->
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
          prerequisites: definition.prerequisites,
          details: result.details
        }
      end)
    end)
  end

  defp compute_project_nodes(scope, ctx) do
    project = scope.active_project
    definitions = RequirementDefinitionData.project_requirements()
    files = ctx.files_by_project || []

    Enum.map(definitions, fn definition ->
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
        prerequisites: definition.prerequisites,
        details: result.details
      }
    end)
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
end
