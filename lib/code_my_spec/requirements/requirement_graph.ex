defmodule CodeMySpec.Requirements.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph from Files + Problems without persisting.

  Three entity levels:
  - **Components**: satisfaction from File existence/validity + Problems
  - **Stories**: satisfaction from Files (bdd_specs, qa) + component tree state
  - **Projects**: satisfaction from Files (architecture, config) + story/component state

  The output is a flat list of computed nodes. Each node carries its entity_type
  and entity_id but the graph structure (edges, actionability) is entity-agnostic:
  edges are same-entity prerequisite links, and cross-entity gates only affect
  whether a node is actionable — they are not represented as edges.
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

  @doc """
  Returns the next actionable requirements across the entire project.

  Computes satisfaction for all requirements at all levels (project, story, component),
  then finds unsatisfied requirements whose prerequisites are all met.

  Cross-entity gates prevent work from being actionable until dependencies in other
  entity levels are satisfied:
  - `bdd_specs_passing` (story) waits for the linked component tree to be fully implemented
  - `project_qa`/`qa_preflight` (project) wait for all stories to be complete

  Sorted by priority: project first, then stories by priority, then components.
  """
  @spec next_actionable(Scope.t()) :: [Requirement.t()]
  def next_actionable(%Scope{} = scope) do
    ctx = Preloader.load(scope)
    all_nodes = compute_all_from_ctx(scope, ctx)

    # Build satisfaction lookup
    satisfaction_map =
      Map.new(all_nodes, fn n ->
        {{n.entity_type, n.entity_id, n.name}, n.satisfied}
      end)

    # Find actionable: unsatisfied, has satisfied_by, all prereqs met, cross-entity gates met
    all_nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        all_prereqs_met?(n, satisfaction_map) and
        cross_entity_gates_met?(n, satisfaction_map, ctx)
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

  defp compute_all_from_ctx(scope, ctx) do
    component_nodes = compute_component_nodes(scope, ctx)
    story_nodes = compute_story_nodes(scope, ctx)
    project_nodes = compute_project_nodes(scope)

    project_nodes ++ story_nodes ++ component_nodes
  end

  # -- Component requirements --

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

  # -- Story requirements --

  defp compute_story_nodes(scope, ctx) do
    stories = ctx.stories
    definitions = RequirementDefinitionData.story_requirements()

    Enum.flat_map(stories, fn story ->
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

  defp check_story("component_linked", _scope, %Story{component_id: nil}, _ctx) do
    {false, %{reason: "No component linked"}}
  end

  defp check_story("component_linked", _scope, %Story{component_id: cid}, _ctx) when not is_nil(cid) do
    {true, %{component_id: cid}}
  end

  defp check_story("bdd_specs_exist", _scope, %Story{id: story_id}, ctx) do
    count =
      ctx.files_by_story
      |> Map.get(story_id, [])
      |> Enum.count(&(&1.role == :bdd_spec))

    if count > 0 do
      {true, %{spec_count: count}}
    else
      {false, %{reason: "No BDD spec files"}}
    end
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

    if has_result do
      {true, %{status: "QA complete"}}
    else
      {false, %{reason: "result_complete.md missing"}}
    end
  end

  defp check_story(name, _scope, _story, _ctx) do
    {false, %{reason: "Unknown story requirement: #{name}"}}
  end

  # -- Project requirements --

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

  defp check_project("technical_strategy", scope, _project) do
    check_file_exists(scope, ".code_my_spec/architecture/decisions.md")
  end

  defp check_project("architecture_designed", scope, _project) do
    check_file_exists(scope, ".code_my_spec/architecture/proposal.md")
  end

  defp check_project("qa_integration_plan", scope, _project) do
    count =
      File
      |> where([f],
        f.project_id == ^scope.active_project_id and
          like(f.path, ^".code_my_spec/integrations/%")
      )
      |> Repo.aggregate(:count)

    if count > 0 do
      {true, %{status: "Integration specs exist"}}
    else
      {false, %{reason: "No integration specs"}}
    end
  end

  defp check_project("issues_triaged", scope, _project) do
    triageable =
      Issues.list_by_status(scope, :incoming)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if triageable == [] do
      {true, %{status: "No untriaged issues at medium+ severity"}}
    else
      {false, %{reason: "#{length(triageable)} untriaged medium+ issues"}}
    end
  end

  defp check_project("issues_resolved", scope, _project) do
    unresolved =
      Issues.list_by_status(scope, :accepted)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if unresolved == [] do
      {true, %{status: "No unresolved medium+ issues"}}
    else
      {false, %{reason: "#{length(unresolved)} unresolved medium+ issues"}}
    end
  end

  defp check_project("qa_preflight", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/preflight.md")
  end

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

      if spex_problems == 0 do
        {true, %{status: "All #{bdd_count} BDD specs passing"}}
      else
        {false, %{reason: "#{spex_problems} failing BDD specs"}}
      end
    end
  end

  defp check_project("qa_journey_plan", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/journey_plan.md")
  end

  defp check_project("qa_journey_execute", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/journey_result.md")
  end

  defp check_project("qa_journey_wallaby", scope, _project) do
    count =
      File
      |> where([f],
        f.project_id == ^scope.active_project_id and
          like(f.path, ^"test/e2e/%")
      )
      |> Repo.aggregate(:count)

    if count > 0 do
      {true, %{status: "#{count} wallaby test files"}}
    else
      {false, %{reason: "No wallaby tests"}}
    end
  end

  defp check_project(name, _scope, _project) do
    {false, %{reason: "Unknown project requirement: #{name}"}}
  end

  # -- Cross-entity gates --
  # These prevent requirements from becoming actionable until work in other
  # entity levels is complete, replacing the old rollup nodes.

  # bdd_specs_passing waits for the story's linked component tree to be fully implemented
  defp cross_entity_gates_met?(
         %{entity_type: "story", entity_id: story_id, name: "bdd_specs_passing"},
         satisfaction_map,
         ctx
       ) do
    story = Enum.find(ctx.stories, &(&1.id == story_id))

    case story do
      %{component_id: component_id} when not is_nil(component_id) ->
        component_tree_satisfied?(component_id, satisfaction_map, ctx)

      _ ->
        false
    end
  end

  # qa_preflight waits for all stories to be complete
  defp cross_entity_gates_met?(
         %{entity_type: "project", name: "qa_preflight"},
         satisfaction_map,
         ctx
       ) do
    all_stories_satisfied?(satisfaction_map, ctx)
  end

  defp cross_entity_gates_met?(_node, _satisfaction_map, _ctx), do: true

  defp component_tree_satisfied?(component_id, satisfaction_map, ctx) do
    tree_ids = collect_component_tree_ids(component_id, ctx.components)

    Enum.all?(tree_ids, fn comp_id ->
      component = Enum.find(ctx.components, &(&1.id == comp_id))

      case component do
        nil ->
          true

        comp ->
          definitions = ComponentRegistry.get_requirements_for_type(comp.type)

          Enum.all?(definitions, fn d ->
            Map.get(satisfaction_map, {"component", comp_id, d.name}, true)
          end)
      end
    end)
  end

  defp collect_component_tree_ids(component_id, components) do
    children = Enum.filter(components, &(&1.parent_component_id == component_id))
    [component_id | Enum.flat_map(children, &collect_component_tree_ids(&1.id, components))]
  end

  defp all_stories_satisfied?(satisfaction_map, ctx) do
    if ctx.stories == [] do
      true
    else
      story_defs = RequirementDefinitionData.story_requirements()

      Enum.all?(ctx.stories, fn story ->
        Enum.all?(story_defs, fn d ->
          Map.get(satisfaction_map, {"story", story.id, d.name}, true)
        end)
      end)
    end
  end

  # -- Helpers --

  defp check_file_exists(scope, path) do
    exists =
      File
      |> where([f], f.project_id == ^scope.active_project_id and f.path == ^path)
      |> Repo.exists?()

    if exists do
      {true, %{path: path}}
    else
      {false, %{reason: "File missing: #{path}"}}
    end
  end

  defp all_prereqs_met?(%{prerequisites: []}, _satisfaction_map), do: true

  defp all_prereqs_met?(%{prerequisites: prereqs, entity_type: type, entity_id: id}, satisfaction_map) do
    Enum.all?(prereqs, fn prereq_name ->
      Map.get(satisfaction_map, {type, id, prereq_name}, true)
    end)
  end

  # -- Priority sorting --

  # Early project requirements: prerequisites are all project-level (or none).
  # Late project requirements: depend on stories/components being done.
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
          if node.name in @late_project_reqs do
            {2, 0, def_order}
          else
            {0, 0, def_order}
          end

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
    |> Repo.one()
    |> case do
      nil -> 999
      p -> p || 999
    end
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

        if parent_id do
          find_story_priority(parent_id, parent_map, story_priorities)
        else
          999
        end

      priority ->
        priority || 999
    end
  end

  defp build_definition_orders do
    component_defs = RequirementDefinitionData.default_requirements()
    story_defs = RequirementDefinitionData.story_requirements()
    project_defs = RequirementDefinitionData.project_requirements()

    orders = %{}

    orders =
      component_defs
      |> Enum.with_index()
      |> Enum.reduce(orders, fn {d, i}, acc -> Map.put(acc, {"component", d.name}, i) end)

    orders =
      story_defs
      |> Enum.with_index()
      |> Enum.reduce(orders, fn {d, i}, acc -> Map.put(acc, {"story", d.name}, i) end)

    project_defs
    |> Enum.with_index()
    |> Enum.reduce(orders, fn {d, i}, acc -> Map.put(acc, {"project", d.name}, i) end)
  end
end
