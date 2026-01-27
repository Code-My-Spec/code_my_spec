defmodule CodeMySpec.Architecture.MermaidProjector do
  @moduledoc """
  Generates a simple Mermaid flowchart showing contexts and their dependency relationships.

  Dependencies are "rolled up" from child components to their parent contexts.
  For example, if `MyApp.Accounts.User` depends on `MyApp.Repo`, the graph shows
  an edge from `MyApp.Accounts` to `MyApp.Repo` (if both are contexts).
  """

  alias CodeMySpec.Components.Component

  @doc """
  Generates a Mermaid flowchart showing contexts and their dependencies.

  ## Parameters
    - components: List of Component structs (should include all components with dependencies preloaded)

  ## Returns
    - String containing Mermaid flowchart syntax
  """
  @spec project([Component.t()]) :: String.t()
  def project(components) do
    contexts = filter_contexts(components)
    context_names = MapSet.new(contexts, & &1.module_name)

    # Build edges by rolling up all component dependencies to context level
    edges = build_rolled_up_edges(components, context_names)

    build_flowchart(contexts, edges)
  end

  defp filter_contexts(components) do
    Enum.filter(components, &(&1.type == "context"))
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

  # Roll up dependencies from all components to their parent contexts
  defp build_rolled_up_edges(components, context_names) do
    components
    |> Enum.flat_map(fn component ->
      source_context = find_parent_context(component.module_name, context_names)
      deps = Map.get(component, :outgoing_dependencies, []) || []

      Enum.map(deps, fn dep ->
        target = dep.target_component
        target_context = find_parent_context(target.module_name, context_names)
        {source_context, target_context}
      end)
    end)
    # Filter out self-loops and nil contexts
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

  # Find the parent context for a module name
  # Returns the module name itself if it's a context, or walks up the namespace
  defp find_parent_context(module_name, context_names) do
    if MapSet.member?(context_names, module_name) do
      module_name
    else
      # Walk up the namespace looking for a context
      parent = parent_module_name(module_name)

      if parent do
        find_parent_context(parent, context_names)
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
