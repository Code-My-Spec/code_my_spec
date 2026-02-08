defmodule CodeMySpec.Requirements.Sync do
  @moduledoc """
  Synchronizes requirements for components.

  Always performs a full recalculation of all requirements on every sync.
  File existence checks are cheap, and dependency/hierarchy checks are
  DB queries — no need for incremental optimization yet.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.{Component, ComponentStatus, DependencyTree, HierarchicalTree, Registry}
  alias CodeMySpec.{Requirements, Utils}
  alias CodeMySpec.Requirements.Requirement
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
    |> HierarchicalTree.build()
    |> Enum.map(&check_dependency_requirements(&1, scope, opts))
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
        if updated.component_status, do: updated, else: Map.put(updated, :component_status, component_status)

      {:error, changeset} ->
        Logger.error("[RequirementsSync] Failed to update component status: #{inspect(changeset.errors)}")
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
        Logger.error("[RequirementsSync] Failed to create requirement: #{inspect(changeset.errors)}")
        nil
    end
  end

  @doc """
  Sorts requirements according to their order in the registry type definition.
  """
  @spec sort_requirements_by_registry_order([Requirement.t()], String.t()) :: [Requirement.t()]
  def sort_requirements_by_registry_order(requirements, component_type) do
    registry_requirements = Registry.get_requirements_for_type(component_type)

    requirement_order =
      registry_requirements
      |> Enum.with_index()
      |> Enum.into(%{}, fn {req_spec, index} -> {req_spec.name, index} end)

    Enum.sort_by(requirements, fn requirement ->
      Map.get(requirement_order, requirement.name, 999)
    end)
  end
end
