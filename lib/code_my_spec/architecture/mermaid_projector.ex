defmodule CodeMySpec.Architecture.MermaidProjector do
  @moduledoc """
  Generates a simple Mermaid flowchart showing contexts, liveviews, and their
  dependency relationships.

  Dependencies are "rolled up" from child components to their parent contexts.
  For example, if `MyApp.Accounts.User` depends on `MyApp.Repo`, the graph shows
  an edge from `MyApp.Accounts` to `MyApp.Repo` (if both are contexts).

  LiveViews appear as their own nodes with edges to the contexts they depend on.
  """

  alias CodeMySpec.Components.Component

  @graph_types ["context", "liveview", "live_context", "controller", "channel"]

  @doc """
  Generates a Mermaid flowchart showing contexts, liveviews, and their dependencies.

  ## Parameters
    - components: List of Component structs (should include all components with dependencies preloaded)

  ## Returns
    - String containing Mermaid flowchart syntax
  """
  @spec project([Component.t()]) :: String.t()
  def project(components) do
    graph_nodes = filter_graph_nodes(components)
    node_names = MapSet.new(graph_nodes, & &1.module_name)

    edges = build_rolled_up_edges(components, node_names)

    build_flowchart(graph_nodes, edges)
  end

  defp filter_graph_nodes(components) do
    Enum.filter(components, &(&1.type in @graph_types))
  end

  defp build_flowchart([], _edges), do: "flowchart TD"

  defp build_flowchart(contexts, edges) do
    nodes = build_nodes(contexts)

    ["flowchart TD" | nodes ++ edges]
    |> Enum.join("\n")
  end

  defp build_nodes(contexts) do
    Enum.map(contexts, &build_node/1)
  end

  defp build_node(%{module_name: module_name}) do
    sanitized_id = sanitize_module_name(module_name)
    "#{sanitized_id}[#{module_name}]"
  end

  # Roll up dependencies from all components to their nearest graph node
  defp build_rolled_up_edges(components, node_names) do
    components
    |> Enum.flat_map(fn component ->
      source_node = find_graph_node(component.module_name, node_names)
      deps = Map.get(component, :outgoing_dependencies, []) || []

      Enum.map(deps, fn dep ->
        target = dep.target_component
        target_node = find_graph_node(target.module_name, node_names)
        {source_node, target_node}
      end)
    end)
    # Filter out self-loops and nil nodes
    |> Enum.filter(fn {source, target} ->
      source != nil and target != nil and source != target
    end)
    # Deduplicate edges
    |> Enum.uniq()
    |> Enum.map(fn {source, target} ->
      source_id = sanitize_module_name(source)
      target_id = sanitize_module_name(target)
      "#{source_id} --> #{target_id}"
    end)
  end

  # Find the nearest graph node for a module name.
  # Returns the module name itself if it's a graph node, or walks up the namespace.
  defp find_graph_node(module_name, node_names) do
    if MapSet.member?(node_names, module_name) do
      module_name
    else
      parent = parent_module_name(module_name)

      if parent do
        find_graph_node(parent, node_names)
      else
        nil
      end
    end
  end

  defp parent_module_name(module_name) do
    parts = String.split(module_name, ".")

    if length(parts) > 1 do
      parts |> Enum.drop(-1) |> Enum.join(".")
    else
      nil
    end
  end

  defp sanitize_module_name(module_name) do
    module_name
    |> String.replace(".", "_")
    |> String.downcase()
  end
end
