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

    satisfaction_map =
      Map.new(nodes, fn n -> {node_key(n), n.satisfied} end)

    incoming =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.update(acc, edge.to, [edge.from], &[edge.from | &1])
      end)

    # Children of contexts are driven by container tasks (context_specs,
    # context_implementation) — not independently actionable.
    driven_child_ids = driven_component_ids(ctx)

    nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        not driven_child?(n, driven_child_ids) and
        incoming_prereqs_satisfied?(n, incoming, satisfaction_map, driven_child_ids)
    end)
    |> sort_by_priority(ctx)
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    compute_all_from_ctx(scope, ctx)
  end

  # -- Edge computation --

  defp compute_edges(nodes, ctx) do
    same_entity_edges(nodes) ++
      project_to_story_edges(ctx) ++
      component_tree_edges(nodes, ctx) ++
      context_container_edges(ctx) ++
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

  # Cross-entity: story.bdd_specs_exist → full component graph → story.bdd_specs_passing
  # The component graph includes hierarchical children AND dependencies (recursively).
  defp component_tree_edges(_nodes, ctx) do
    ctx.stories
    |> Enum.filter(&(&1.component_id != nil))
    |> Enum.flat_map(fn story ->
      all_ids = collect_all_component_ids(story.component_id, ctx.components, MapSet.new())

      component_endpoints =
        all_ids
        |> Enum.map(fn comp_id ->
          comp = Enum.find(ctx.components, &(&1.id == comp_id))
          if comp do
            defs = ComponentRegistry.get_requirements_for_type(comp.type)
            first = List.first(defs)
            terminal = List.last(defs)
            {comp_id, first && first.name, terminal && terminal.name}
          end
        end)
        |> Enum.reject(&is_nil/1)

      # Edge: bdd_specs_exist → root component's first req
      root_comp = Enum.find(component_endpoints, fn {id, _, _} -> id == story.component_id end)

      entry_edges =
        case root_comp do
          {comp_id, first_name, _} when not is_nil(first_name) ->
            [%{from: {"story", story.id, "bdd_specs_exist"}, to: {"component", comp_id, first_name}}]
          _ -> []
        end

      # Edges: each component's terminal req → bdd_specs_passing
      exit_edges =
        Enum.flat_map(component_endpoints, fn
          {comp_id, _, terminal_name} when not is_nil(terminal_name) ->
            [%{from: {"component", comp_id, terminal_name}, to: {"story", story.id, "bdd_specs_passing"}}]
          _ -> []
        end)

      entry_edges ++ exit_edges
    end)
  end

  # Cross-entity edges between parent contexts and children.
  # Data-driven: when a child's requirement has a prerequisite that exists
  # on the parent context but NOT on the child itself, create a cross-entity
  # edge from parent.prereq → child.req.
  # Fan-in: child's terminal req → parent's implementation_file.
  defp context_container_edges(ctx) do
    context_types = MapSet.new(["context", "coordination_context"])

    ctx.components
    |> Enum.filter(fn c -> c.type in context_types end)
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
      node.scope == :children and MapSet.member?(driven_child_ids, source_id)
    end)
    |> Enum.all?(fn source_key ->
      Map.get(satisfaction_map, source_key, true)
    end)
  end

  # Components whose parent context has :children scope containers
  defp driven_component_ids(ctx) do
    context_types = MapSet.new(["context", "coordination_context"])

    context_ids =
      ctx.components
      |> Enum.filter(fn c -> c.type in context_types end)
      |> MapSet.new(& &1.id)

    ctx.components
    |> Enum.filter(fn c ->
      c.parent_component_id && MapSet.member?(context_ids, c.parent_component_id)
    end)
    |> MapSet.new(& &1.id)
  end

  defp driven_child?(%{entity_type: "component", entity_id: id}, driven_ids) do
    MapSet.member?(driven_ids, id)
  end

  defp driven_child?(_, _), do: false

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


  # -- Priority sorting --

  @late_project_reqs MapSet.new([
    "qa_preflight", "all_bdd_specs_passing",
    "qa_journey_plan", "qa_journey_execute", "qa_journey_wallaby"
  ])

  defp sort_by_priority(nodes, ctx) do
    story_priorities =
      ctx.stories
      |> Enum.filter(& &1.component_id)
      |> Map.new(&{&1.component_id, &1.priority})

    story_by_id = Map.new(ctx.stories, &{&1.id, &1})
    parent_map = Map.new(ctx.components, &{&1.id, &1.parent_component_id})
    component_story_map = build_component_story_map(ctx.components, story_priorities, parent_map)
    definition_orders = build_definition_orders()

    Enum.sort_by(nodes, fn node ->
      def_order = Map.get(definition_orders, {node.entity_type, node.name}, 999)

      case node.entity_type do
        "project" ->
          if node.name in @late_project_reqs, do: {2, 0, def_order}, else: {0, 0, def_order}

        "story" ->
          priority = (story_by_id[node.entity_id] && story_by_id[node.entity_id].priority) || 999
          {1, priority, def_order}

        "component" ->
          {1, Map.get(component_story_map, node.entity_id, 999), def_order}
      end
    end)
  end

  defp build_component_story_map(components, story_priorities, parent_map) do
    Map.new(components, fn comp ->
      priority = find_story_priority(comp.id, parent_map, story_priorities)
      {comp.id, priority}
    end)
  end

  defp find_story_priority(nil, _parent_map, _story_priorities), do: 999

  defp find_story_priority(component_id, parent_map, story_priorities) do
    case Map.get(story_priorities, component_id) do
      nil ->
        parent_id = Map.get(parent_map, component_id)
        if parent_id, do: find_story_priority(parent_id, parent_map, story_priorities), else: 999

      priority ->
        priority || 999
    end
  end

  defp build_definition_orders do
    component_defs = RequirementDefinitionData.default_requirements()
    story_defs = RequirementDefinitionData.story_requirements()
    project_defs = RequirementDefinitionData.project_requirements()

    %{}
    |> add_orders(component_defs, "component")
    |> add_orders(story_defs, "story")
    |> add_orders(project_defs, "project")
  end

  defp add_orders(orders, defs, type) do
    defs
    |> Enum.with_index()
    |> Enum.reduce(orders, fn {d, i}, acc -> Map.put(acc, {type, d.name}, i) end)
  end
end
