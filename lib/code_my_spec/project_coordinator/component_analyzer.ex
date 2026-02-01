defmodule CodeMySpec.ProjectCoordinator.ComponentAnalyzer do
  @moduledoc """
  Analyzes components against file system reality by mapping expected file paths,
  checking file existence, and looking up test status. Returns Component structs
  with ComponentStatus embedded and nested dependency trees.
  """

  alias CodeMySpec.Components.{
    Component,
    ComponentStatus,
    DependencyTree,
    HierarchicalTree,
    Registry
  }

  alias CodeMySpec.{Requirements, Utils, Components}
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Tests.TestResult
  alias CodeMySpec.Users.Scope
  require Logger

  @dependency_checks ["dependencies_satisfied"]
  @hierarchy_checks ["children_designs", "children_implementations", "children_tests"]

  @spec analyze_components([Component.t()], [String.t()], [TestResult.t()], keyword()) ::
          [Component.t()]
  @spec analyze_components([CodeMySpec.Components.Component.t()], [binary()], [
          CodeMySpec.Tests.TestResult.t()
        ]) :: [CodeMySpec.Components.Component.t()]
  def analyze_components(components, file_list, failures, opts \\ []) do
    scope = Keyword.get(opts, :scope, %Scope{})

    components
    |> Enum.map(&Requirements.clear_requirements(scope, &1, opts))
    |> Enum.map(&analyze_local_component_status(&1, file_list, failures, scope, opts))
    |> Enum.map(&check_local_requirements(&1, scope, opts))
    |> DependencyTree.build()
    |> HierarchicalTree.build()
    |> Enum.map(&check_dependency_requirements(&1, scope, opts))
    |> Enum.sort_by(& &1.name)
  end

  defp analyze_local_component_status(component, file_list, failing_tests, scope, opts) do
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
    # component.requirements is already a list from check_local_requirements
    all_requirements =
      (component.requirements ++ dependency_requirements)
      |> sort_requirements_by_registry_order(component.type)

    %{component | requirements: all_requirements}
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
