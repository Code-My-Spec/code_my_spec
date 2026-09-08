defmodule CodeMySpec.Architecture.NamespaceProjector do
  @moduledoc """
  Generates hierarchical tree views of components organized by Elixir module namespace.

  Produces indented text trees showing the structural organization of the codebase by module path.
  """

  alias CodeMySpec.Components.Component

  @doc """
  Generates a namespace hierarchy tree from a list of components.

  Returns a formatted string showing the hierarchical organization by module namespace.

  ## Examples

      iex> components = [%Component{module_name: "CodeMySpec.Components", type: "context", description: "Component management"}]
      iex> NamespaceProjector.project(components)
      "CodeMySpec.Components [context] Component management"

  """
  @spec project([Component.t()]) :: String.t()
  def project([]), do: ""

  def project([single_component]) do
    # Special case: single component shown flat without tree structure
    format_single_component(single_component)
  end

  def project(components) do
    project(components, [])
  end

  @doc """
  Generates a namespace hierarchy tree with configurable options.

  ## Options

    * `:show_types` - Include component type badges (default: true)
    * `:show_descriptions` - Include component descriptions (default: true)
    * `:max_depth` - Limit tree depth to specified level (default: nil - unlimited)
    * `:filter_prefix` - Show only components matching namespace prefix (default: nil - all)

  ## Examples

      iex> components = [%Component{module_name: "CodeMySpec.Components", type: "context", description: "Component management"}]
      iex> NamespaceProjector.project(components, show_types: false)
      "CodeMySpec.Components Component management"

  """
  @spec project([Component.t()], keyword()) :: String.t()
  def project([], _options), do: ""

  def project([single_component], options) do
    # Special case: single component shown flat without tree structure
    show_types = Keyword.get(options, :show_types, true)
    show_descriptions = Keyword.get(options, :show_descriptions, true)
    format_single_component(single_component, show_types, show_descriptions)
  end

  def project(components, options) do
    show_types = Keyword.get(options, :show_types, true)
    show_descriptions = Keyword.get(options, :show_descriptions, true)
    max_depth = Keyword.get(options, :max_depth)
    filter_prefix = Keyword.get(options, :filter_prefix)

    filtered_components = filter_by_prefix(components, filter_prefix)

    case filtered_components do
      [] ->
        ""

      [single] ->
        format_single_component(single, show_types, show_descriptions)

      multiple ->
        multiple
        |> build_tree()
        |> format_tree(show_types, show_descriptions, max_depth)
    end
  end

  # Private Functions

  defp format_single_component(component) do
    format_single_component(component, true, true)
  end

  defp format_single_component(component, show_types, show_descriptions) do
    parts = [component.module_name]

    parts =
      if show_types do
        parts ++ ["[#{component.type}]"]
      else
        parts
      end

    parts =
      if show_descriptions && component.description do
        sanitized = sanitize_description_for_tree(component.description)
        parts ++ [sanitized]
      else
        parts
      end

    Enum.join(parts, " ")
  end

  defp filter_by_prefix(components, nil), do: components

  defp filter_by_prefix(components, prefix) do
    Enum.filter(components, fn component ->
      String.starts_with?(component.module_name, prefix)
    end)
  end

  defp build_tree(components) do
    # Create a map of module_name -> component for quick lookup
    component_map =
      components
      |> Enum.map(fn component -> {component.module_name, component} end)
      |> Map.new()

    # Parse all module paths into namespace segments
    module_paths =
      components
      |> Enum.map(fn component ->
        segments = String.split(component.module_name, ".")
        {segments, component}
      end)

    # Build nested tree structure
    tree = build_tree_node(module_paths, component_map, [])

    tree
  end

  defp build_tree_node(paths, component_map, current_path) do
    # Group paths by their next segment
    grouped =
      paths
      |> Enum.group_by(
        fn {segments, _component} ->
          case Enum.drop(segments, length(current_path)) do
            [next | _] -> next
            [] -> nil
          end
        end,
        fn {_segments, component} -> component end
      )
      |> Map.delete(nil)

    # Build children nodes
    grouped
    |> Enum.map(fn {segment, components_in_group} ->
      new_path = current_path ++ [segment]
      full_module_name = Enum.join(new_path, ".")

      # Check if this exact path has a component
      component = Map.get(component_map, full_module_name)

      # Recursively build children for paths that continue deeper
      children =
        components_in_group
        |> Enum.filter(fn comp -> comp.module_name != full_module_name end)
        |> Enum.map(fn comp -> {String.split(comp.module_name, "."), comp} end)
        |> build_tree_node(component_map, new_path)

      %{
        segment: segment,
        full_path: new_path,
        component: component,
        children: Enum.sort_by(children, & &1.segment)
      }
    end)
    |> Enum.sort_by(& &1.segment)
  end

  defp format_tree(tree, show_types, show_descriptions, max_depth) do
    tree
    |> format_nodes([], show_types, show_descriptions, max_depth, 0)
    |> Enum.join("\n")
  end

  defp format_nodes([], _prefix, _show_types, _show_descriptions, _max_depth, _depth), do: []

  defp format_nodes(_nodes, _prefix, _show_types, _show_descriptions, max_depth, depth)
       when not is_nil(max_depth) and depth >= max_depth do
    []
  end

  defp format_nodes(nodes, prefix, show_types, show_descriptions, max_depth, depth) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      is_last = index == length(nodes) - 1
      format_node(node, prefix, is_last, show_types, show_descriptions, max_depth, depth)
    end)
  end

  defp format_node(node, prefix, is_last, show_types, show_descriptions, max_depth, depth) do
    # Determine tree characters
    {connector, child_prefix_addon} =
      case {depth, is_last} do
        {0, _} -> {"", ""}
        {_, true} -> {"└── ", "    "}
        {_, false} -> {"├── ", "│   "}
      end

    # Build the line for this node
    line_parts = [
      Enum.join(prefix),
      connector,
      node.segment,
      format_component_info(node.component, show_types, show_descriptions)
    ]

    line = line_parts |> Enum.reject(&(&1 == "")) |> Enum.join()

    # Format children
    child_prefix = prefix ++ [child_prefix_addon]

    children_lines =
      format_nodes(
        node.children,
        child_prefix,
        show_types,
        show_descriptions,
        max_depth,
        depth + 1
      )

    [line | children_lines]
  end

  defp format_component_info(nil, _show_types, _show_descriptions), do: ""

  defp format_component_info(component, show_types, show_descriptions) do
    parts = []

    parts =
      if show_types do
        parts ++ [" [#{component.type}]"]
      else
        parts
      end

    parts =
      if show_descriptions && component.description do
        sanitized = sanitize_description_for_tree(component.description)
        parts ++ [" #{sanitized}"]
      else
        parts
      end

    Enum.join(parts)
  end

  # Collapse description to single line, truncate if too long
  defp sanitize_description_for_tree(nil), do: ""

  defp sanitize_description_for_tree(description) do
    description
    |> String.trim()
    # Remove **Type**: prefix
    |> String.replace(~r/^\*\*Type\*\*:\s*\w+\s*/i, "")
    # Replace newlines with spaces
    |> String.replace(~r/\s*\n\s*/, " ")
    # Collapse multiple spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    # Truncate to reasonable length for tree view
    |> truncate(120)
  end

  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string

  defp truncate(string, max_length) do
    String.slice(string, 0, max_length - 3) <> "..."
  end
end
