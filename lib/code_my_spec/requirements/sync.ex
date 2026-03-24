defmodule CodeMySpec.Requirements.Sync do
  @moduledoc """
  Synchronizes requirements for components, stories, and projects.

  Always performs a full recalculation of all requirements on every sync.
  File existence checks are cheap, and dependency/hierarchy checks are
  DB queries — no need for incremental optimization yet.
  """

  require Logger

  alias CodeMySpec.Components

  alias CodeMySpec.Components.{
    Component,
    ComponentStatus,
    DependencyTree,
    HierarchicalTree
  }

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.{Requirements, Utils}
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Tests.TestResult
  alias CodeMySpec.Users.Scope

  @dependency_checks ["dependencies_satisfied"]
  @hierarchy_checks ["children_designs", "children_implementations", "children_tests"]

  @doc """
  Synchronizes requirements for all components.

  Updates ComponentStatus for every component (cheap file_list membership check),
  then clears and recalculates all requirements.

  ## Parameters

  - `scope` - User scope
  - `components` - All components in the project
  - `changed_component_ids` - MapSet of component IDs that changed (currently unused)
  - `file_list` - List of all file paths in the project
  - `test_results` - Test run results (failures)
  - `opts` - Options

  ## Returns

  List of components with updated requirements.
  """
  @spec sync_requirements(
          Scope.t(),
          [Component.t()],
          MapSet.t(),
          [String.t()],
          [TestResult.t()],
          keyword()
        ) :: [Component.t()]
  def sync_requirements(
        scope,
        components,
        _changed_component_ids,
        file_list,
        test_results,
        opts \\ []
      ) do
    start = System.monotonic_time(:millisecond)

    # Deduplicate by component ID (duplicates cause unique constraint violations)
    components = Enum.uniq_by(components, & &1.id)

    # Phase 1: Update ComponentStatus for all components (cheap file_list membership)
    components_with_status =
      Enum.map(components, &analyze_component_status(&1, file_list, test_results, scope, opts))

    status_ms = System.monotonic_time(:millisecond) - start

    # Phase 2: Full requirements recalculation
    result = sync_all_requirements(components_with_status, scope, opts)

    total_ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[RequirementsSync] #{length(components)} components synced in #{total_ms}ms " <>
        "(status: #{status_ms}ms, requirements: #{total_ms - status_ms}ms)"
    )

    result
  end

  @doc """
  Clears and recalculates all requirements for every component.
  """
  @spec sync_all_requirements([Component.t()], Scope.t(), keyword()) :: [Component.t()]
  def sync_all_requirements(components, scope, opts \\ []) do
    opts = Keyword.put(opts, :persist, true)

    components
    |> Enum.map(&Requirements.clear_requirements(scope, &1, opts))
    |> Enum.map(&check_local_requirements(&1, scope, opts))
    |> DependencyTree.build()
    |> HierarchicalTree.enrich()
    |> Enum.map(&check_dependency_requirements(&1, scope, opts))
    # Re-enrich so nested child_components reflect the full requirement set
    # (the first enrich() captures children before dependency requirements are added)
    |> HierarchicalTree.enrich()
    |> Enum.sort_by(& &1.name)
  end

  # --- Private: Component status analysis ---

  defp analyze_component_status(component, file_list, failing_tests, scope, opts) do
    expected_files = Utils.component_files(component, component.project)
    actual_files = check_file_existence(expected_files, file_list)
    relevant_failing_tests = filter_failing_tests(expected_files, failing_tests)

    component_status =
      ComponentStatus.from_analysis(expected_files, actual_files, relevant_failing_tests)

    update_attrs = %{component_status: component_status}
    opts = Keyword.put(opts, :broadcast, false)

    case Components.update_component(scope, component, update_attrs, opts) do
      {:ok, updated} ->
        if updated.component_status,
          do: updated,
          else: Map.put(updated, :component_status, component_status)

      {:error, changeset} ->
        Logger.error(
          "[RequirementsSync] Failed to update component status: #{inspect(changeset.errors)}"
        )

        Map.put(component, :component_status, component_status)
    end
  end

  defp check_file_existence(expected_files, file_list) do
    expected_files
    |> Map.values()
    |> Enum.filter(&(&1 in file_list))
  end

  defp filter_failing_tests(expected_files, failing_tests) do
    expected_test_file = expected_files.test_file

    failing_tests
    |> Enum.filter(fn %TestResult{} = result -> result.error.file == expected_test_file end)
    |> Enum.map(& &1.full_title)
  end

  # --- Private: Requirements checking ---

  defp check_local_requirements(component, scope, opts) do
    filter_opts = Keyword.put(opts, :exclude, @hierarchy_checks ++ @dependency_checks)
    definitions = Components.get_requirement_definitions(scope, component, filter_opts)

    requirements =
      Requirements.check_requirements(scope, component, definitions, opts)
      |> Enum.map(&create_requirement(scope, component, &1, opts))
      |> Enum.reject(&is_nil/1)

    %{component | requirements: requirements}
  end

  defp check_dependency_requirements(component, scope, opts) do
    filter_opts = Keyword.put(opts, :include, @dependency_checks ++ @hierarchy_checks)
    definitions = Components.get_requirement_definitions(scope, component, filter_opts)

    dependency_requirements =
      Requirements.check_requirements(scope, component, definitions, opts)
      |> Enum.map(&create_requirement(scope, component, &1, opts))
      |> Enum.reject(&is_nil/1)

    all_requirements =
      (component.requirements ++ dependency_requirements)
      |> sort_requirements_by_registry_order(component.type)

    %{component | requirements: all_requirements}
  end

  defp create_requirement(scope, component, requirement_attrs, opts) do
    case Requirements.create_requirement(scope, component, requirement_attrs, opts) do
      {:ok, requirement} ->
        Map.put(requirement, :component, %Ecto.Association.NotLoaded{})

      {:error, changeset} ->
        Logger.error(
          "[RequirementsSync] Failed to create requirement: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  @doc """
  Recalculates requirements for a single component and its ancestors.

  Walks up the parent chain, clearing and rechecking requirements at each level.
  Used by the file watcher to keep requirements current on every file change.
  """
  @spec recalculate_component_requirements(Scope.t(), Component.t()) :: :ok
  def recalculate_component_requirements(scope, %Component{} = component) do
    opts = [persist: true]
    start = System.monotonic_time(:millisecond)

    component_with_reqs =
      component
      |> preload_for_requirements(scope)
      |> then(&Requirements.clear_requirements(scope, &1, opts))
      |> then(&check_local_requirements(&1, scope, opts))
      |> then(&check_dependency_requirements(&1, scope, opts))

    ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[RequirementsSync] Recalculated #{length(component_with_reqs.requirements)} requirements for #{component.module_name} in #{ms}ms"
    )

    # Walk up to parent and recalculate
    case component.parent_component_id do
      nil ->
        :ok

      parent_id ->
        case Components.get_component(scope, parent_id) do
          nil -> :ok
          parent -> recalculate_component_requirements(scope, parent)
        end
    end
  end

  defp preload_for_requirements(component, scope) do
    component
    |> CodeMySpec.Repo.preload([
      :requirements,
      :project,
      dependencies: :requirements,
      child_components: :requirements
    ])
    |> Map.put(:project, scope.active_project)
  end

  @doc """
  Synchronizes requirements for all stories in the project.

  Clears and recalculates all story-level requirements.
  """
  @spec sync_story_requirements([Story.t()], Scope.t(), keyword()) :: [Story.t()]
  def sync_story_requirements(stories, scope, opts \\ []) do
    opts = Keyword.put(opts, :persist, true)
    definitions = RequirementsRegistry.get_story_requirements()

    stories
    |> Enum.map(fn story ->
      Requirements.clear_story_requirements(scope, story, opts)

      requirements =
        Requirements.check_requirements(scope, story, definitions, opts)
        |> Enum.map(&create_story_requirement(scope, story, &1, opts))
        |> Enum.reject(&is_nil/1)

      %{story | requirements: requirements}
    end)
  end

  @doc """
  Synchronizes requirements for the project itself.

  Clears and recalculates all project-level requirements.
  """
  @spec sync_project_requirements(Scope.t(), keyword()) :: Project.t()
  def sync_project_requirements(scope, opts \\ []) do
    opts = Keyword.put(opts, :persist, true)
    project = scope.active_project
    definitions = RequirementsRegistry.get_project_requirements()

    Logger.info("[RequirementsSync] Syncing #{length(definitions)} project requirements: #{inspect(Enum.map(definitions, & &1.name))}")

    Requirements.clear_project_requirements(scope, project, opts)

    check_results = Requirements.check_requirements(scope, project, definitions, opts)
    Logger.info("[RequirementsSync] Check results: #{inspect(Enum.map(check_results, fn r -> {r.name, r.satisfied} end))}")

    requirements =
      check_results
      |> Enum.map(fn result ->
        case create_project_requirement(scope, project, result, opts) do
          nil ->
            Logger.error("[RequirementsSync] Failed to persist: #{result.name}")
            nil
          req ->
            req
        end
      end)
      |> Enum.reject(&is_nil/1)

    Logger.info("[RequirementsSync] Persisted #{length(requirements)} project requirements")

    %{project | requirements: requirements}
  end

  @doc """
  Cascades requirement recalculation from changed components up to stories and project.

  After component requirements are recalculated, this syncs requirements for
  stories linked to those components, then syncs project requirements.
  """
  @spec cascade_from_components(Scope.t(), [String.t()]) :: :ok
  def cascade_from_components(_scope, []), do: :ok

  def cascade_from_components(scope, changed_component_ids) when is_list(changed_component_ids) do
    start = System.monotonic_time(:millisecond)
    changed_set = MapSet.new(changed_component_ids)

    # Find stories linked to changed components
    affected_stories =
      case CodeMySpec.Stories.list_project_stories(scope) do
        {:ok, stories} ->
          stories
          |> Enum.filter(&(&1.component_id in changed_set))
          |> CodeMySpec.Repo.preload([:requirements, :component])

        _ ->
          []
      end

    # Sync story requirements for affected stories
    if affected_stories != [] do
      sync_story_requirements(affected_stories, scope)
    end

    # Sync project requirements (depends on story state)
    sync_project_requirements(scope)

    ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[RequirementsSync] Cascaded to #{length(affected_stories)} stories + project in #{ms}ms"
    )

    :ok
  end

  @doc """
  Rechecks a single requirement by ID.

  Loads the requirement, finds its definition from the registry,
  runs the checker, and upserts the result.
  """
  @spec recheck_requirement(Scope.t(), integer()) :: :ok
  def recheck_requirement(scope, requirement_id) do
    requirement = Requirements.get_requirement!(requirement_id)
    {entity, definitions} = entity_and_definitions(requirement)
    definition = Enum.find(definitions, &(&1.name == requirement.name))

    [result] = Requirements.check_requirements(scope, entity, [definition], persist: true)

    case entity do
      %Component{} -> Requirements.create_requirement(scope, entity, result, persist: true)
      %Story{} -> Requirements.create_story_requirement(scope, entity, result, persist: true)
      %Project{} -> Requirements.create_project_requirement(scope, entity, result, persist: true)
    end

    :ok
  end

  defp entity_and_definitions(%Requirement{component: %Component{} = component}) do
    {component, RequirementsRegistry.get_requirements_for_type(component.type)}
  end

  defp entity_and_definitions(%Requirement{story: %Story{} = story}) do
    {story, RequirementsRegistry.get_story_requirements()}
  end

  defp entity_and_definitions(%Requirement{project: %Project{} = project}) do
    {project, RequirementsRegistry.get_project_requirements()}
  end

  @doc """
  Sorts requirements according to their order in the registry type definition.
  """
  @spec sort_requirements_by_registry_order([Requirement.t()], String.t()) :: [Requirement.t()]
  def sort_requirements_by_registry_order(requirements, component_type) do
    registry_requirements = RequirementsRegistry.get_requirements_for_type(component_type)

    requirement_order =
      registry_requirements
      |> Enum.with_index()
      |> Enum.into(%{}, fn {req_spec, index} -> {req_spec.name, index} end)

    Enum.sort_by(requirements, fn requirement ->
      Map.get(requirement_order, requirement.name, 999)
    end)
  end

  # --- Private: Story/Project requirement creation ---

  defp create_story_requirement(scope, story, requirement_attrs, opts) do
    case Requirements.create_story_requirement(scope, story, requirement_attrs, opts) do
      {:ok, requirement} ->
        requirement

      {:error, changeset} ->
        Logger.error(
          "[RequirementsSync] Failed to create story requirement: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  defp create_project_requirement(scope, project, requirement_attrs, opts) do
    case Requirements.create_project_requirement(scope, project, requirement_attrs, opts) do
      {:ok, requirement} ->
        requirement

      {:error, changeset} ->
        Logger.error(
          "[RequirementsSync] Failed to create project requirement: #{inspect(changeset.errors)}"
        )

        nil
    end
  end
end
