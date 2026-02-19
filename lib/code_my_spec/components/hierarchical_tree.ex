defmodule CodeMySpec.Components.HierarchicalTree do
  @moduledoc """
  Build nested hierarchical trees for components based on parent-child relationships.

  Unlike dependency trees which require topological sorting to handle cycles,
  hierarchical trees are naturally acyclic tree structures that can be built
  through simple recursive traversal.
  """

  alias CodeMySpec.Components.Component
  require Logger

  @type component_map :: %{integer() => Component.t()}
  @type visited_set :: MapSet.t(integer())

  @doc """
  Build hierarchical trees for all components.

  Returns components with nested child_components built recursively.
  Root components (those without parents) are returned at the top level.
  """
  @spec build([Component.t()]) :: [Component.t()]
  def build([]), do: []

  def build(components) when is_list(components) do
    component_map = build_component_map(components)
    root_components = find_root_components(components)

    root_components
    |> Enum.map(&build_nested_tree(&1, component_map, MapSet.new()))
  end

  @doc """
  Enrich all components with their nested child_components.

  Unlike `build/1` which returns only root components, this returns ALL
  components with their `child_components` populated. Use this when you
  need child data on every component (e.g., for requirements checking).
  """
  @spec enrich([Component.t()]) :: [Component.t()]
  def enrich([]), do: []

  def enrich(components) when is_list(components) do
    component_map = build_component_map(components)

    Enum.map(components, fn component ->
      children = build_nested_children(component, component_map, MapSet.new([component.id]))
      %{component | child_components: children}
    end)
  end

  @doc """
  Build hierarchical tree for a single component.

  Recursively builds nested child_components using all available components.
  """
  @spec build(Component.t(), [Component.t()]) :: Component.t()
  def build(component, all_components) do
    component_map = build_component_map(all_components)
    visited = MapSet.new()

    build_nested_tree(component, component_map, visited)
  end

  @doc """
  Get all descendants of a component (children, grandchildren, etc).
  """
  @spec get_all_descendants(Component.t(), [Component.t()]) :: [Component.t()]
  def get_all_descendants(component, all_components) do
    component_map = build_component_map(all_components)
    collect_descendants(component, component_map, MapSet.new(), [])
  end

  @doc """
  Get the full path from root to a component.
  """
  @spec get_component_path(Component.t(), [Component.t()]) :: [Component.t()]
  def get_component_path(component, all_components) do
    component_map = build_component_map(all_components)
    build_path_to_root(component, component_map, [])
  end

  @doc """
  Check if component A is an ancestor of component B.
  """
  @spec ancestor?(Component.t(), Component.t(), [Component.t()]) :: boolean()
  def ancestor?(potential_ancestor, component, all_components) do
    # Component cannot be its own ancestor
    if potential_ancestor.id == component.id do
      false
    else
      path = get_component_path(component, all_components)
      Enum.any?(path, fn ancestor -> ancestor.id == potential_ancestor.id end)
    end
  end

  @spec find_root_components([Component.t()]) :: [Component.t()]
  defp find_root_components(components) do
    components
    |> Enum.filter(fn component -> is_nil(component.parent_component_id) end)
  end

  @spec build_component_map([Component.t()]) :: component_map()
  defp build_component_map(components) do
    components
    |> Enum.into(%{}, fn component -> {component.id, component} end)
  end

  @spec build_nested_tree(Component.t(), component_map(), visited_set()) :: Component.t()
  defp build_nested_tree(component, component_map, visited) do
    if MapSet.member?(visited, component.id) do
      Logger.warning("Cycle detected in hierarchy for component #{component.id}, breaking cycle")
      %{component | child_components: []}
    else
      updated_visited = MapSet.put(visited, component.id)
      nested_children = build_nested_children(component, component_map, updated_visited)
      %{component | child_components: nested_children}
    end
  end

  @spec build_nested_children(Component.t(), component_map(), visited_set()) :: [Component.t()]
  defp build_nested_children(component, component_map, visited) do
    # Always find children by parent_component_id since child_components won't be loaded
    component_map
    |> Map.values()
    |> Enum.filter(fn child -> child.parent_component_id == component.id end)
    |> Enum.map(fn child -> build_nested_tree(child, component_map, visited) end)
  end

  @spec collect_descendants(Component.t(), component_map(), visited_set(), [Component.t()]) :: [
          Component.t()
        ]
  defp collect_descendants(component, component_map, visited, acc) do
    if MapSet.member?(visited, component.id) do
      acc
    else
      updated_visited = MapSet.put(visited, component.id)
      children = get_direct_children(component, component_map)

      children_acc = acc ++ children

      children
      |> Enum.reduce(children_acc, fn child, current_acc ->
        collect_descendants(child, component_map, updated_visited, current_acc)
      end)
    end
  end

  @spec get_direct_children(Component.t(), component_map()) :: [Component.t()]
  defp get_direct_children(component, component_map) do
    # Always find children by parent_component_id since child_components won't be loaded
    component_map
    |> Map.values()
    |> Enum.filter(fn child -> child.parent_component_id == component.id end)
  end

  @spec build_path_to_root(Component.t(), component_map(), [Component.t()]) :: [Component.t()]
  defp build_path_to_root(component, component_map, path) do
    updated_path = [component | path]

    case component.parent_component_id do
      nil ->
        updated_path

      parent_id ->
        case Map.get(component_map, parent_id) do
          nil ->
            updated_path

          parent ->
            build_path_to_root(parent, component_map, updated_path)
        end
    end
  end
end
