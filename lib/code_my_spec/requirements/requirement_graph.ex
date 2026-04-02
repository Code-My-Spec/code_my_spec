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

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files.File
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
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
    |> sort_by_priority(scope)
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
    project_nodes = compute_project_nodes(scope)

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
      Enum.map(definitions, fn definition ->
        {satisfied, details} = check_story(definition.name, scope, story, ctx)

        %Requirement{
          entity_type: "story",
          entity_id: story.id,
          entity_name: story.title,
          name: definition.name,
          description: definition.description,
          satisfied: satisfied,
          satisfied_by: definition.satisfied_by,
          scope: definition.scope || :local,
          execution_type: definition.execution_type || :main_agent,
          validation_type: definition.validation_type || :automatic,
          prerequisites: definition.prerequisites,
          details: details
        }
      end)
    end)
  end

  defp check_story("component_linked", _scope, %Story{component_id: nil}, _ctx),
    do: {false, %{reason: "No component linked"}}

  defp check_story("component_linked", _scope, %Story{component_id: cid}, _ctx) when not is_nil(cid),
    do: {true, %{component_id: cid}}

  defp check_story("bdd_specs_exist", _scope, %Story{id: story_id}, ctx) do
    count = ctx.files_by_story |> Map.get(story_id, []) |> Enum.count(&(&1.role == :bdd_spec))
    if count > 0, do: {true, %{spec_count: count}}, else: {false, %{reason: "No BDD spec files"}}
  end

  defp check_story("bdd_specs_passing", scope, %Story{id: story_id}, ctx) do
    bdd_files = ctx.files_by_story |> Map.get(story_id, []) |> Enum.filter(&(&1.role == :bdd_spec))

    spex_problems =
      Problem
      |> where([p], p.project_id == ^scope.active_project_id and p.source == "spex")
      |> Repo.aggregate(:count)

    cond do
      bdd_files == [] -> {false, %{reason: "No BDD specs to check"}}
      spex_problems > 0 -> {false, %{reason: "#{spex_problems} failing BDD spec(s)"}}
      true -> {true, %{status: "All BDD specs passing"}}
    end
  end

  defp check_story("qa_complete", scope, %Story{id: story_id}, _ctx) do
    has_result =
      File
      |> where([f],
        f.project_id == ^scope.active_project_id and
          f.story_id == ^story_id and
          f.role == :qa_result and
          f.path == ^".code_my_spec/qa/#{story_id}/result_complete.md"
      )
      |> Repo.exists?()

    if has_result, do: {true, %{status: "QA complete"}}, else: {false, %{reason: "result_complete.md missing"}}
  end

  defp check_story(name, _scope, _story, _ctx),
    do: {false, %{reason: "Unknown story requirement: #{name}"}}

  defp compute_project_nodes(scope) do
    project = scope.active_project
    definitions = RequirementDefinitionData.project_requirements()

    Enum.map(definitions, fn definition ->
      {satisfied, details} = check_project(definition.name, scope, project)

      %Requirement{
        entity_type: "project",
        entity_id: project.id,
        entity_name: project.name,
        name: definition.name,
        description: definition.description,
        satisfied: satisfied,
        satisfied_by: definition.satisfied_by,
        scope: definition.scope || :local,
        execution_type: definition.execution_type || :main_agent,
        validation_type: definition.validation_type || :automatic,
        prerequisites: definition.prerequisites,
        details: details
      }
    end)
  end

  defp check_project("project_setup", scope, _project) do
    case CodeMySpec.AgentTasks.ProjectSetup.evaluate(scope, %{}) do
      {:ok, :valid} -> {true, %{status: "All setup steps complete"}}
      {:ok, :invalid, _} -> {false, %{reason: "Setup steps incomplete"}}
      _ -> {false, %{reason: "Setup evaluation failed"}}
    end
  end

  defp check_project("technical_strategy", scope, _project),
    do: check_file_exists(scope, ".code_my_spec/architecture/decisions.md")

  defp check_project("architecture_designed", scope, _project),
    do: check_file_exists(scope, ".code_my_spec/architecture/proposal.md")

  defp check_project("qa_integration_plan", scope, _project) do
    count =
      File
      |> where([f], f.project_id == ^scope.active_project_id and like(f.path, ^".code_my_spec/integrations/%"))
      |> Repo.aggregate(:count)

    if count > 0, do: {true, %{status: "Integration specs exist"}}, else: {false, %{reason: "No integration specs"}}
  end

  defp check_project("issues_triaged", scope, _project) do
    triageable =
      Issues.list_by_status(scope, :incoming)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if triageable == [],
      do: {true, %{status: "No untriaged issues at medium+ severity"}},
      else: {false, %{reason: "#{length(triageable)} untriaged medium+ issues"}}
  end

  defp check_project("issues_resolved", scope, _project) do
    unresolved =
      Issues.list_by_status(scope, :accepted)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if unresolved == [],
      do: {true, %{status: "No unresolved medium+ issues"}},
      else: {false, %{reason: "#{length(unresolved)} unresolved medium+ issues"}}
  end

  defp check_project("qa_preflight", scope, _project),
    do: check_file_exists(scope, ".code_my_spec/qa/preflight.md")

  defp check_project("all_bdd_specs_passing", scope, _project) do
    bdd_count =
      File
      |> where([f], f.project_id == ^scope.active_project_id and f.role == :bdd_spec)
      |> Repo.aggregate(:count)

    if bdd_count == 0 do
      {false, %{reason: "No BDD specs exist"}}
    else
      spex_problems =
        Problem
        |> where([p], p.project_id == ^scope.active_project_id and p.source == "spex")
        |> Repo.aggregate(:count)

      if spex_problems == 0,
        do: {true, %{status: "All #{bdd_count} BDD specs passing"}},
        else: {false, %{reason: "#{spex_problems} failing BDD specs"}}
    end
  end

  defp check_project("qa_journey_plan", scope, _project),
    do: check_file_exists(scope, ".code_my_spec/qa/journey_plan.md")

  defp check_project("qa_journey_execute", scope, _project),
    do: check_file_exists(scope, ".code_my_spec/qa/journey_result.md")

  defp check_project("qa_journey_wallaby", scope, _project) do
    count =
      File
      |> where([f], f.project_id == ^scope.active_project_id and like(f.path, ^"test/e2e/%"))
      |> Repo.aggregate(:count)

    if count > 0, do: {true, %{status: "#{count} wallaby test files"}}, else: {false, %{reason: "No wallaby tests"}}
  end

  defp check_project(name, _scope, _project),
    do: {false, %{reason: "Unknown project requirement: #{name}"}}

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

  defp check_file_exists(scope, path) do
    exists =
      File
      |> where([f], f.project_id == ^scope.active_project_id and f.path == ^path)
      |> Repo.exists?()

    if exists, do: {true, %{path: path}}, else: {false, %{reason: "File missing: #{path}"}}
  end

  # -- Priority sorting --

  @late_project_reqs MapSet.new([
    "qa_preflight", "all_bdd_specs_passing",
    "qa_journey_plan", "qa_journey_execute", "qa_journey_wallaby"
  ])

  defp sort_by_priority(nodes, %Scope{active_project_id: project_id}) do
    story_priorities =
      Story
      |> where([s], s.project_id == ^project_id and not is_nil(s.component_id))
      |> select([s], {s.component_id, s.priority})
      |> Repo.all()
      |> Map.new()

    component_story_map = build_component_story_map(project_id, story_priorities)
    definition_orders = build_definition_orders()

    Enum.sort_by(nodes, fn node ->
      def_order = Map.get(definition_orders, {node.entity_type, node.name}, 999)

      case node.entity_type do
        "project" ->
          if node.name in @late_project_reqs, do: {2, 0, def_order}, else: {0, 0, def_order}

        "story" ->
          {1, story_priority(node.entity_id, project_id), def_order}

        "component" ->
          {1, Map.get(component_story_map, node.entity_id, 999), def_order}
      end
    end)
  end

  defp story_priority(story_id, project_id) do
    Story
    |> where([s], s.id == ^story_id and s.project_id == ^project_id)
    |> select([s], s.priority)
    |> Repo.one() || 999
  end

  defp build_component_story_map(project_id, story_priorities) do
    components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> select([c], {c.id, c.parent_component_id})
      |> Repo.all()

    parent_map = Map.new(components, fn {id, parent_id} -> {id, parent_id} end)

    Map.new(components, fn {id, _} ->
      priority = find_story_priority(id, parent_map, story_priorities)
      {id, priority}
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
