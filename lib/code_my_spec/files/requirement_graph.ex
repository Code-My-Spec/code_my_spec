defmodule CodeMySpec.Files.RequirementGraph do
  @moduledoc """
  Computes the full requirement graph from Files + Problems without persisting.

  Replaces `RequirementsRepository.next_actionable_project` with a version that
  computes satisfaction on the fly from File records and Problems.

  Three entity levels:
  - **Components**: satisfaction from File existence/validity + Problems
  - **Stories**: satisfaction from Files (bdd_specs, qa) + component tree state
  - **Projects**: satisfaction from Files (architecture, config) + story/component state
  """

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.RequirementCalculator
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type computed_node :: %{
          entity_type: String.t(),
          entity_id: Ecto.UUID.t() | integer(),
          entity_name: String.t(),
          name: String.t(),
          description: String.t(),
          satisfied: boolean(),
          satisfied_by: module() | nil,
          execution_type: :main_agent | :sub_agent,
          validation_type: :automatic | :manual,
          prerequisites: [String.t()],
          details: map()
        }

  @doc """
  Returns the next actionable requirements across the entire project.

  Computes satisfaction for all requirements at all levels (project, story, component),
  then finds unsatisfied requirements whose prerequisites are all met.

  Sorted by priority: project first, then stories by priority, then components.
  """
  @spec next_actionable(Scope.t()) :: [computed_node()]
  def next_actionable(%Scope{} = scope) do
    all_nodes = compute_all(scope)

    # Build satisfaction lookup
    satisfaction_map =
      Map.new(all_nodes, fn n ->
        {{n.entity_type, n.entity_id, n.name}, n.satisfied}
      end)

    # Find actionable: unsatisfied, has satisfied_by, all prereqs met
    all_nodes
    |> Enum.filter(fn n ->
      not n.satisfied and
        not is_nil(n.satisfied_by) and
        all_prereqs_met?(n, satisfaction_map)
    end)
    |> sort_by_priority(scope)
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [computed_node()]
  def compute_all(%Scope{} = scope) do
    component_nodes = compute_component_nodes(scope)
    story_nodes = compute_story_nodes(scope)
    project_nodes = compute_project_nodes(scope)

    project_nodes ++ story_nodes ++ component_nodes
  end

  # -- Component requirements --

  defp compute_component_nodes(scope) do
    components = Components.list_components(scope)

    Enum.flat_map(components, fn component ->
      definitions = ComponentRegistry.get_requirements_for_type(component.type)
      files = load_component_files(scope, component.id)

      Enum.map(definitions, fn definition ->
        result = RequirementCalculator.compute_one(scope, component, definition, files)

        %{
          entity_type: "component",
          entity_id: component.id,
          entity_name: component.module_name,
          name: definition.name,
          description: definition.description,
          satisfied: result.satisfied,
          satisfied_by: definition.satisfied_by,
          execution_type: definition.execution_type || :main_agent,
          validation_type: definition.validation_type || :automatic,
          prerequisites: definition.prerequisites,
          details: result.details
        }
      end)
    end)
  end

  # -- Story requirements --

  defp compute_story_nodes(scope) do
    stories = load_stories(scope)
    definitions = RequirementDefinitionData.story_requirements()

    Enum.flat_map(stories, fn story ->
      Enum.map(definitions, fn definition ->
        {satisfied, details} = check_story(definition.name, scope, story)

        %{
          entity_type: "story",
          entity_id: story.id,
          entity_name: story.title,
          name: definition.name,
          description: definition.description,
          satisfied: satisfied,
          satisfied_by: definition.satisfied_by,
          execution_type: definition.execution_type || :main_agent,
          validation_type: definition.validation_type || :automatic,
          prerequisites: definition.prerequisites,
          details: details
        }
      end)
    end)
  end

  defp check_story("component_linked", _scope, %Story{component_id: nil}) do
    {false, %{reason: "No component linked"}}
  end

  defp check_story("component_linked", _scope, %Story{component_id: cid}) when not is_nil(cid) do
    {true, %{component_id: cid}}
  end

  defp check_story("bdd_specs_exist", scope, %Story{id: story_id}) do
    count = count_story_files(scope, story_id, :bdd_spec)

    if count > 0 do
      {true, %{spec_count: count}}
    else
      {false, %{reason: "No BDD spec files"}}
    end
  end

  defp check_story("component_complete", _scope, %Story{component_id: nil}) do
    {false, %{reason: "No component linked"}}
  end

  defp check_story("component_complete", scope, %Story{component_id: component_id}) do
    case Components.get_component(scope, component_id) do
      nil ->
        {false, %{reason: "Component not found"}}

      component ->
        if RequirementCalculator.component_satisfied?(scope, component) do
          {true, %{status: "Component tree satisfied"}}
        else
          {false, %{reason: "Component tree has unsatisfied requirements"}}
        end
    end
  end

  defp check_story("bdd_specs_passing", scope, %Story{id: story_id}) do
    count = count_story_problems(scope, story_id, "spex")

    if count == 0 do
      bdd_count = count_story_files(scope, story_id, :bdd_spec)

      if bdd_count > 0 do
        {true, %{status: "All BDD specs passing"}}
      else
        {false, %{reason: "No BDD specs to check"}}
      end
    else
      {false, %{reason: "#{count} failing BDD spec(s)"}}
    end
  end

  defp check_story("qa_complete", scope, %Story{id: story_id}) do
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

  defp check_story(name, _scope, _story) do
    {false, %{reason: "Unknown story requirement: #{name}"}}
  end

  # -- Project requirements --

  defp compute_project_nodes(scope) do
    project = scope.active_project
    definitions = RequirementDefinitionData.project_requirements()

    Enum.map(definitions, fn definition ->
      {satisfied, details} = check_project(definition.name, scope, project)

      %{
        entity_type: "project",
        entity_id: project.id,
        entity_name: project.name,
        name: definition.name,
        description: definition.description,
        satisfied: satisfied,
        satisfied_by: definition.satisfied_by,
        execution_type: definition.execution_type || :main_agent,
        validation_type: definition.validation_type || :automatic,
        prerequisites: definition.prerequisites,
        details: details
      }
    end)
  end

  defp check_project("project_setup", scope, _project) do
    # Delegate to ProjectSetup step evaluation
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
    check_file_exists(scope, ".code_my_spec/architecture/overview.md")
  end

  defp check_project("qa_integration_plan", scope, _project) do
    # Check if integrations directory has specs
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
    # Check for incoming issues
    incoming_count =
      File
      |> where([f],
        f.project_id == ^scope.active_project_id and
          like(f.path, ^".code_my_spec/issues/incoming/%")
      )
      |> Repo.aggregate(:count)

    if incoming_count == 0 do
      {true, %{status: "No incoming issues"}}
    else
      {false, %{reason: "#{incoming_count} untriaged issues"}}
    end
  end

  defp check_project("issues_resolved", scope, _project) do
    # Check for accepted issues
    accepted_count =
      File
      |> where([f],
        f.project_id == ^scope.active_project_id and
          like(f.path, ^".code_my_spec/issues/accepted/%")
      )
      |> Repo.aggregate(:count)

    if accepted_count == 0 do
      {true, %{status: "No unresolved issues"}}
    else
      {false, %{reason: "#{accepted_count} unresolved issues"}}
    end
  end

  defp check_project("all_stories_complete", scope, _project) do
    stories = load_stories(scope)
    story_defs = RequirementDefinitionData.story_requirements()

    if stories == [] do
      {true, %{status: "No stories"}}
    else
      incomplete =
        Enum.reject(stories, fn story ->
          Enum.all?(story_defs, fn def ->
            {sat, _} = check_story(def.name, scope, story)
            sat
          end)
        end)

      if incomplete == [] do
        {true, %{status: "All #{length(stories)} stories complete"}}
      else
        {false, %{reason: "#{length(incomplete)} incomplete stories"}}
      end
    end
  end

  defp check_project("qa_preflight", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/preflight.md")
  end

  defp check_project("all_bdd_specs_passing", scope, _project) do
    spex_problems =
      Problem
      |> where([p], p.project_id == ^scope.active_project_id and p.source == "spex")
      |> Repo.aggregate(:count)

    if spex_problems == 0 do
      {true, %{status: "All BDD specs passing"}}
    else
      {false, %{reason: "#{spex_problems} failing BDD specs"}}
    end
  end

  defp check_project("qa_journey_plan", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/journey_plan.md")
  end

  defp check_project("qa_journey_execute", scope, _project) do
    check_file_exists(scope, ".code_my_spec/qa/journey_result.md")
  end

  defp check_project("qa_journey_wallaby", scope, _project) do
    # Check for wallaby test files
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

  defp load_component_files(%Scope{active_project_id: project_id}, component_id) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> Repo.all()
  end

  defp load_stories(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id)
    |> Repo.all()
  end

  defp count_story_files(%Scope{active_project_id: project_id}, story_id, role) do
    File
    |> where([f], f.project_id == ^project_id and f.story_id == ^story_id and f.role == ^role)
    |> Repo.aggregate(:count)
  end

  defp count_story_problems(%Scope{active_project_id: project_id}, _story_id, source) do
    # Story problems are tracked via component — for now check project-wide spex
    Problem
    |> where([p], p.project_id == ^project_id and p.source == ^source)
    |> Repo.aggregate(:count)
  end

  # -- Priority sorting --

  defp sort_by_priority(nodes, %Scope{active_project_id: project_id}) do
    story_priorities =
      Story
      |> where([s], s.project_id == ^project_id and not is_nil(s.component_id))
      |> select([s], {s.component_id, s.priority})
      |> Repo.all()
      |> Map.new()

    # Map component_id → story priority by walking parent chains
    component_story_map = build_component_story_map(project_id, story_priorities)

    definition_orders = build_definition_orders()

    Enum.sort_by(nodes, fn node ->
      def_order = Map.get(definition_orders, {node.entity_type, node.name}, 999)

      case node.entity_type do
        "project" -> {0, 0, def_order}
        "story" -> {1, story_priority(node.entity_id, project_id), def_order}
        "component" -> {1, Map.get(component_story_map, node.entity_id, 999), def_order}
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
