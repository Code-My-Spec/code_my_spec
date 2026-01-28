defmodule CodeMySpec.Requirements.Sync do
  @moduledoc """
  Synchronizes requirements for components. Provides both full sync and
  selective sync based on which components changed.

  ## Optimization Strategy

  Only recalculates requirements for components that:
  - Had their files changed (in changed_component_ids)
  - Have dependencies that changed (dependency tree affected)
  - Had their parent changed (hierarchy affected)

  This avoids clearing and recalculating requirements for unchanged components.
  """

  require Logger

  import Ecto.Query, only: [where: 3]

  alias CodeMySpec.Repo
  alias CodeMySpec.Components

  alias CodeMySpec.Components.{
    Component,
    ComponentStatus,
    DependencyTree,
    HierarchicalTree,
    Registry
  }

  alias CodeMySpec.{Requirements, Utils}
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Tests.TestResult
  alias CodeMySpec.Users.Scope

  @dependency_checks ["dependencies_satisfied"]
  @hierarchy_checks ["children_designs", "children_implementations", "children_tests"]

  @doc """
  Synchronizes requirements for changed components only.

  Takes a list of all components and the IDs of components that changed.
  Only clears and recalculates requirements for changed components and
  components affected by the changes.

  ## Parameters

  - `scope` - User scope
  - `components` - All components in the project
  - `changed_component_ids` - MapSet of component IDs that changed
  - `file_list` - List of all file paths in the project
  - `test_run` - Test run results (failures)
  - `opts` - Options (force, etc.)

  ## Options

  - `:force` - When true, syncs all components (defaults to false)

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
        changed_component_ids,
        file_list,
        test_results,
        opts \\ []
      ) do
    force = Keyword.get(opts, :force, false)

    # Always update component_status (cheap: just file existence checks)
    components_with_status =
      Enum.map(components, &analyze_component_status(&1, file_list, test_results, scope, opts))

    if force do
      # Force mode: clear and recalculate all requirements
      sync_all_requirements(components_with_status, scope, opts)
    else
      # Incremental mode: only sync affected components
      sync_changed_requirements(components_with_status, changed_component_ids, scope, opts)
    end
  end

  @doc """
  Synchronizes requirements for all components (full sync).

  This is the backward-compatible interface that clears and recalculates
  requirements for every component.

  ## Parameters

  - `scope` - User scope
  - `components` - All components in the project
  - `file_list` - List of all file paths in the project
  - `test_run` - Test run results (failures)
  - `opts` - Options

  ## Returns

  List of components with updated requirements.
  """
  @spec sync_all_requirements([Component.t()], Scope.t(), keyword()) :: [Component.t()]
  def sync_all_requirements(components, scope, opts \\ []) do
    # Ensure persist: true so clear_requirements actually deletes from DB
    opts = Keyword.put(opts, :persist, true)

    # Note: This doesn't update component_status since it doesn't have file_list or test_results
    # Use sync_requirements/6 for full sync with component_status updates
    components
    |> Enum.map(&Requirements.clear_requirements(scope, &1, opts))
    |> Enum.map(&check_local_requirements(&1, scope, opts))
    |> DependencyTree.build()
    |> HierarchicalTree.build()
    |> Enum.map(&check_dependency_requirements(&1, scope, opts))
    |> Enum.sort(&(&1.priority <= &2.priority))
  end

  # --- Private: Incremental sync ---

  defp clear_dependency_requirements(_scope, components, opts) do
    # Clear only dependency and hierarchy requirements (not local requirements like spec_file, impl_file, etc)
    dependency_and_hierarchy_names = @dependency_checks ++ @hierarchy_checks

    Enum.each(components, fn component ->
      if Keyword.get(opts, :persist, false) do
        Requirement
        |> where([r], r.component_id == ^component.id)
        |> where([r], r.name in ^dependency_and_hierarchy_names)
        |> Repo.delete_all()
      end
    end)
  end

  defp sync_changed_requirements(components, changed_component_ids, scope, opts) do
    # Preload requirements for all components (needed for dependency checks)
    # This is still an optimization because we only RECALCULATE for changed components
    components = Repo.preload(components, :requirements)

    # Build dependency tree to identify affected components (don't build hierarchy yet)
    components_with_deps = DependencyTree.build(components)

    # Identify components that need requirements recalculation
    affected_ids = identify_affected_components(components_with_deps, changed_component_ids)

    # Safety net: components with 0 requirements should also be treated as affected
    # This catches cases where components were synced but requirements weren't created
    components_missing_requirements =
      components_with_deps
      |> Enum.filter(fn c -> length(c.requirements || []) == 0 end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    affected_ids = MapSet.union(affected_ids, components_missing_requirements)

    if MapSet.size(components_missing_requirements) > 0 do
      Logger.info(
        "[RequirementsSync] Found #{MapSet.size(components_missing_requirements)} components with 0 requirements, adding to affected set"
      )
    end

    # Clear and recalculate requirements only for affected components
    # Ensure persist: true so clear_requirements actually deletes from DB
    clear_opts = Keyword.put(opts, :persist, true)

    components_with_local_requirements =
      Enum.map(components_with_deps, fn component ->
        if component.id in affected_ids do
          Requirements.clear_requirements(scope, component, clear_opts)
          check_local_requirements(component, scope, opts)
        else
          # Keep existing requirements (already loaded from DB)
          component
        end
      end)

    # NOW build hierarchy tree with updated requirements
    components_with_hierarchy = HierarchicalTree.build(components_with_local_requirements)

    # Always check dependency requirements (may depend on changed components)
    # Need to clear existing dependency/hierarchy requirements for all components first
    clear_dependency_requirements(scope, components_with_hierarchy, clear_opts)

    components_with_hierarchy
    |> Enum.map(&check_dependency_requirements(&1, scope, opts))
    |> Enum.sort(&(&1.priority <= &2.priority))
  end

  defp identify_affected_components(components, changed_component_ids) do
    # Build lookup maps
    component_map = Map.new(components, &{&1.id, &1})

    # Start with directly changed components
    initial_affected = changed_component_ids

    # Expand to include:
    # 1. Components that depend on changed components
    # 2. Parents of changed components (hierarchy affects parent requirements)
    # 3. Children of changed components (parent change affects children)
    expanded_affected =
      components
      |> Enum.reduce(initial_affected, fn component, affected_set ->
        cond do
          # Component itself changed
          component.id in affected_set ->
            affected_set

          # Component depends on a changed component
          depends_on_changed?(component, affected_set) ->
            MapSet.put(affected_set, component.id)

          # Component's parent changed
          parent_changed?(component, affected_set) ->
            MapSet.put(affected_set, component.id)

          # Component has a child that changed
          has_changed_child?(component, affected_set, component_map) ->
            MapSet.put(affected_set, component.id)

          true ->
            affected_set
        end
      end)

    expanded_affected
  end

  defp depends_on_changed?(component, changed_ids) do
    component.dependencies
    |> Enum.any?(fn dep -> dep.id in changed_ids end)
  end

  defp parent_changed?(component, changed_ids) do
    component.parent_component_id && component.parent_component_id in changed_ids
  end

  defp has_changed_child?(component, changed_ids, component_map) do
    component.child_components
    |> Enum.any?(fn child ->
      case Map.get(component_map, child.id) do
        nil -> false
        child_component -> child_component.id in changed_ids
      end
    end)
  end

  # --- Private: Component status analysis ---

  defp analyze_component_status(component, file_list, failing_tests, scope, opts) do
    # Compute ComponentStatus from file system analysis
    expected_files = Utils.component_files(component, component.project)
    actual_files = check_file_existence(expected_files, file_list)
    relevant_failing_tests = filter_failing_tests(expected_files, failing_tests)

    component_status =
      ComponentStatus.from_analysis(expected_files, actual_files, relevant_failing_tests)

    update_attrs = %{component_status: component_status}
    opts = Keyword.put(opts, :broadcast, false)

    case Components.update_component(scope, component, update_attrs, opts) do
      {:ok, updated_component} ->
        # Ensure component_status is present (defensive programming)
        if updated_component.component_status do
          updated_component
        else
          Map.put(updated_component, :component_status, component_status)
        end

      {:error, changeset} ->
        Logger.error("#{__MODULE__} failed to update component", changeset: changeset)
        # Fallback: manually set component_status if update failed
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
    |> Enum.filter(fn %TestResult{} = result ->
      result.error.file == expected_test_file
    end)
    |> Enum.map(& &1.full_title)
  end

  # --- Private: Requirements checking ---

  defp check_local_requirements(component, scope, opts) do
    filter_opts = Keyword.put(opts, :exclude, @hierarchy_checks ++ @dependency_checks)

    definitions = Components.get_requirement_definitions(scope, component, filter_opts)

    requirements =
      Requirements.check_requirements(scope, component, definitions, opts)
      |> Enum.map(fn requirement_attrs ->
        case Requirements.create_requirement(
               scope,
               component,
               requirement_attrs,
               opts
             ) do
          {:ok, requirement} ->
            Map.put(requirement, :component, %Ecto.Association.NotLoaded{})

          {:error, changeset} ->
            Logger.error("#{__MODULE__} failed check_local_requirements",
              changeset: changeset
            )

            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    %{component | requirements: requirements}
  end

  defp check_dependency_requirements(component, scope, opts) do
    filter_opts = Keyword.put(opts, :include, @dependency_checks ++ @hierarchy_checks)

    definitions = Components.get_requirement_definitions(scope, component, filter_opts)

    dependency_requirements =
      Requirements.check_requirements(scope, component, definitions, opts)
      |> Enum.map(fn requirement_attrs ->
        case Requirements.create_requirement(
               scope,
               component,
               requirement_attrs,
               opts
             ) do
          {:ok, requirement} ->
            Map.put(requirement, :component, %Ecto.Association.NotLoaded{})

          {:error, changeset} ->
            Logger.error("#{__MODULE__} failed check_dependency_requirements",
              changeset: changeset
            )

            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    # Merge dependency requirements with existing requirements
    # component.requirements is already a list from check_local_requirements or preloaded
    all_requirements =
      (component.requirements ++ dependency_requirements)
      |> sort_requirements_by_registry_order(component.type)

    %{component | requirements: all_requirements}
  end

  @doc """
  Sorts requirements according to their order in the registry type definition.
  """
  @spec sort_requirements_by_registry_order([Requirement.t()], String.t()) ::
          [Requirement.t()]
  def sort_requirements_by_registry_order(requirements, component_type) do
    registry_requirements = Registry.get_requirements_for_type(component_type)

    requirement_order =
      registry_requirements
      |> Enum.with_index()
      |> Enum.into(%{}, fn {req_spec, index} -> {req_spec.name, index} end)

    requirements
    |> Enum.sort_by(fn requirement ->
      Map.get(requirement_order, requirement.name, 999)
    end)
  end
end
