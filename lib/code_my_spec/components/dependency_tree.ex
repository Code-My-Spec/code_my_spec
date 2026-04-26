defmodule CodeMySpec.Components.DependencyTree do
  @moduledoc """
  Build nested dependency trees for components by processing them in optimal order.

  Uses topological sorting to ensure all dependencies are fully analyzed before
  dependent components, enabling efficient construction of nested dependency trees.
  """

  alias CodeMySpec.Components.Component
  require Logger

  @type component_map :: %{integer() => Component.t()}
  @type visited_set :: MapSet.t(integer())

  @doc """
  Apply dependency tree processing to all components.

  Returns components with nested dependency trees built through topological sorting.
  """
  @spec build([Component.t()]) :: [Component.t()]
  def build([]), do: []

  def build(components) when is_list(components) do
    components
    |> topological_sort()
    |> Enum.reduce(%{}, &fold_processed_component/2)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp fold_processed_component(component, processed_map) do
    nested_dependencies = nested_deps(component.dependencies, processed_map)
    updated_component = %{component | dependencies: nested_dependencies}
    Map.put(processed_map, component.id, updated_component)
  end

  # Build nested dependencies using only already-processed components.
  defp nested_deps(%Ecto.Association.NotLoaded{}, _processed_map), do: []

  defp nested_deps(dependencies, processed_map) when is_list(dependencies) do
    Enum.map(dependencies, &Map.get(processed_map, &1.id, &1))
  end

  @doc """
  Apply dependency tree processing to a single component.

  Builds nested dependency tree for the given component using all available components.
  """
  @spec build(Component.t(), [Component.t()]) :: Component.t()
  def build(component, all_components) do
    component_map = build_component_map(all_components)
    visited = MapSet.new()

    build_nested_tree(component, component_map, visited)
  end

  @spec build_component_map([Component.t()]) :: component_map()
  defp build_component_map(components) do
    components
    |> Enum.into(%{}, fn component -> {component.id, component} end)
  end

  @spec topological_sort([Component.t()]) :: [Component.t()]
  defp topological_sort(components) do
    in_degree_map = calculate_in_degrees(components)
    initial_queue = find_zero_in_degree_components(components, in_degree_map)

    sort_components(initial_queue, in_degree_map, components, MapSet.new(), [])
  end

  @spec calculate_in_degrees([Component.t()]) :: %{integer() => non_neg_integer()}
  defp calculate_in_degrees(components) do
    components
    |> Enum.into(%{}, fn component ->
      dependency_count =
        case component.dependencies do
          %Ecto.Association.NotLoaded{} -> 0
          dependencies -> length(dependencies)
        end

      {component.id, dependency_count}
    end)
  end

  @spec find_zero_in_degree_components([Component.t()], %{integer() => non_neg_integer()}) :: [
          Component.t()
        ]
  defp find_zero_in_degree_components(components, in_degree_map) do
    components
    |> Enum.filter(fn component -> Map.get(in_degree_map, component.id) == 0 end)
  end

  @spec sort_components(
          [Component.t()],
          %{integer() => non_neg_integer()},
          [Component.t()],
          MapSet.t(integer()),
          [Component.t()]
        ) :: [Component.t()]
  defp sort_components([], _in_degree_map, all_components, processed, result) do
    unprocessed_components =
      all_components
      |> Enum.reject(fn component -> MapSet.member?(processed, component.id) end)

    case unprocessed_components do
      [] ->
        Enum.reverse(result)

      remaining ->
        Logger.warning("Dependency cycle detected, processing remaining components")
        Enum.reverse(result) ++ remaining
    end
  end

  defp sort_components([current | queue_rest], in_degree_map, all_components, processed, result) do
    # Skip if already processed
    if MapSet.member?(processed, current.id) do
      sort_components(queue_rest, in_degree_map, all_components, processed, result)
    else
      # Mark as processed
      updated_processed = MapSet.put(processed, current.id)

      # Find dependents (components that depend on current)
      dependents = find_dependents(current, all_components)

      # Update in-degrees and find newly zero-degree components
      {updated_in_degrees, new_zero_components} =
        update_in_degrees(dependents, in_degree_map, processed)

      # Add new zero-degree components to queue (avoiding duplicates)
      updated_queue =
        queue_rest ++
          Enum.reject(new_zero_components, fn comp ->
            MapSet.member?(updated_processed, comp.id) or
              Enum.any?(queue_rest, &(&1.id == comp.id))
          end)

      sort_components(updated_queue, updated_in_degrees, all_components, updated_processed, [
        current | result
      ])
    end
  end

  @spec find_dependents(Component.t(), [Component.t()]) :: [Component.t()]
  defp find_dependents(component, components) do
    # Find components that have `component` in their dependencies
    components
    |> Enum.filter(fn comp ->
      case comp.dependencies do
        %Ecto.Association.NotLoaded{} -> false
        dependencies -> Enum.any?(dependencies, fn dep -> dep.id == component.id end)
      end
    end)
  end

  @spec update_in_degrees([Component.t()], %{integer() => non_neg_integer()}, MapSet.t(integer())) ::
          {%{integer() => non_neg_integer()}, [Component.t()]}
  defp update_in_degrees(dependents, in_degree_map, processed) do
    updated_in_degrees =
      dependents
      |> Enum.reduce(in_degree_map, fn dependent, acc ->
        current_degree = Map.get(acc, dependent.id, 0)
        Map.put(acc, dependent.id, max(0, current_degree - 1))
      end)

    new_zero_components =
      dependents
      |> Enum.filter(fn dependent ->
        Map.get(updated_in_degrees, dependent.id) == 0 and
          not MapSet.member?(processed, dependent.id)
      end)

    {updated_in_degrees, new_zero_components}
  end

  @spec build_nested_tree(Component.t(), component_map(), visited_set()) :: Component.t()
  defp build_nested_tree(component, component_map, visited) do
    if MapSet.member?(visited, component.id) do
      Logger.warning("Cycle detected for component #{component.id}, breaking cycle")
      %{component | dependencies: []}
    else
      updated_visited = MapSet.put(visited, component.id)
      nested_dependencies = build_nested_dependencies(component, component_map, updated_visited)
      %{component | dependencies: nested_dependencies}
    end
  end

  @spec build_nested_dependencies(Component.t(), component_map(), visited_set()) :: [
          Component.t()
        ]
  defp build_nested_dependencies(component, component_map, visited) do
    case component.dependencies do
      %Ecto.Association.NotLoaded{} ->
        []

      dependencies ->
        Enum.map(dependencies, &resolve_dependency(&1, component_map, visited))
    end
  end

  defp resolve_dependency(dependency, component_map, visited) do
    case Map.get(component_map, dependency.id) do
      nil -> dependency
      found_component -> build_nested_tree(found_component, component_map, visited)
    end
  end
end
