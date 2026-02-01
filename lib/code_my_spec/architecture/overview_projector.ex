defmodule CodeMySpec.Architecture.OverviewProjector do
  @moduledoc """
  Generates comprehensive markdown overviews of all components organized by context.

  Lists components with types, descriptions, and dependencies in a format optimized
  for AI agent consumption during design sessions.
  """

  alias CodeMySpec.Components.Component

  @doc """
  Generates a comprehensive markdown overview of all components organized by their parent contexts.

  ## Process
  1. Group components by parent context using parent_component_id
  2. Build markdown document starting with a title header
  3. For each context in the grouped results:
     - Add H2 header with context name
     - Include context type and description if available
     - List all child components under the context
  4. For each component, format entry with:
     - H3 header with component name
     - Type badge in bold
     - Description on new line if present
     - Dependencies section listing module names
  5. Handle components with no parent (root level) in separate section
  6. Return complete markdown string

  ## Examples

      iex> OverviewProjector.project([])
      "# Architecture Overview\\n"

      iex> context = %Component{name: "Stories", type: "context"}
      iex> OverviewProjector.project([context])
      "# Architecture Overview\\n\\n## Stories\\n\\n**context**\\n..."
  """
  @spec project([Component.t()]) :: String.t()
  def project(components) do
    project(components, [])
  end

  @doc """
  Generates a comprehensive markdown overview with configurable options for filtering and formatting.

  ## Options
  - `:include_descriptions` - Include component descriptions (default: true)
  - `:include_dependencies` - Include dependency listings (default: true)
  - `:context_filter` - List of context module names to filter by (default: nil, includes all)

  ## Examples

      iex> OverviewProjector.project(components, include_descriptions: false)
      "# Architecture Overview\\n..."

      iex> OverviewProjector.project(components, context_filter: ["CodeMySpec.Stories"])
      "# Architecture Overview\\n\\n## Stories\\n..."
  """
  @spec project([Component.t()], keyword()) :: String.t()
  def project(components, options) do
    include_descriptions = Keyword.get(options, :include_descriptions, true)
    include_dependencies = Keyword.get(options, :include_dependencies, true)
    context_filter = Keyword.get(options, :context_filter, nil)

    components
    |> filter_by_contexts(context_filter)
    |> group_by_parent()
    |> build_markdown(include_descriptions, include_dependencies)
  end

  # Private Functions

  defp filter_by_contexts(components, nil), do: components

  defp filter_by_contexts(components, context_module_names) do
    # Build a map of context IDs that match the filter
    context_ids =
      components
      |> Enum.filter(fn component ->
        component.module_name in context_module_names
      end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    # Filter to contexts in the filter list and their children
    Enum.filter(components, fn component ->
      component.module_name in context_module_names or
        (component.parent_component_id &&
           component.parent_component_id in context_ids)
    end)
  end

  defp group_by_parent(components) do
    # Separate contexts (components with no parent or that are contexts themselves)
    # from child components
    {contexts, children} =
      Enum.split_with(components, fn component ->
        component.parent_component_id == nil
      end)

    # Group children by their parent_component_id
    children_by_parent = Enum.group_by(children, & &1.parent_component_id)

    # Sort contexts alphabetically by name
    sorted_contexts = Enum.sort_by(contexts, & &1.name)

    {sorted_contexts, children_by_parent}
  end

  defp build_markdown({contexts, children_by_parent}, include_descriptions, include_dependencies) do
    sections =
      contexts
      |> Enum.map(fn context ->
        format_context_section(
          context,
          children_by_parent,
          include_descriptions,
          include_dependencies
        )
      end)
      |> Enum.reject(&(&1 == ""))

    title = "# Architecture Overview\n"

    if Enum.empty?(sections) do
      title
    else
      title <> "\n" <> Enum.join(sections, "\n")
    end
  end

  defp format_context_section(
         context,
         children_by_parent,
         include_descriptions,
         include_dependencies
       ) do
    # Determine the section header
    section_header =
      if context.parent_component_id == nil && context.type != "context" do
        "## Root Components\n\n"
      else
        "## #{context.name}\n\n"
      end

    # Format the context itself as a component
    context_content =
      format_component(context, include_descriptions, include_dependencies)

    # Get children for this context and sort them
    children = Map.get(children_by_parent, context.id, [])
    sorted_children = sort_components(children)

    # Format all children using map_join for efficiency
    children_content =
      Enum.map_join(
        sorted_children,
        "\n",
        &format_component(&1, include_descriptions, include_dependencies)
      )

    # Combine sections
    content_parts =
      [context_content, children_content]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if content_parts == "" do
      ""
    else
      section_header <> content_parts <> "\n"
    end
  end

  defp format_component(component, include_descriptions, include_dependencies) do
    parts = []

    # Component header
    parts = parts ++ ["### #{component.name}\n"]

    # Type badge
    parts = parts ++ ["**#{component.type}**\n"]

    # Description (if enabled and present) - use first paragraph only
    parts =
      if include_descriptions && component.description do
        sanitized = sanitize_description(component.description)
        parts ++ ["\n#{sanitized}\n"]
      else
        parts
      end

    # Dependencies (if enabled and present)
    parts =
      if include_dependencies && has_dependencies?(component) do
        parts ++ [format_dependencies(component)]
      else
        parts
      end

    Enum.join(parts, "")
  end

  defp has_dependencies?(%Component{dependencies: []}), do: false
  defp has_dependencies?(%Component{dependencies: [_ | _]}), do: true
  defp has_dependencies?(_), do: false

  defp format_dependencies(%Component{dependencies: dependencies}) do
    dependency_list =
      Enum.map_join(dependencies, "\n", fn dep -> "- #{dep.module_name}" end)

    "\nDependencies:\n#{dependency_list}\n"
  end

  defp sort_components(components) do
    Enum.sort_by(components, & &1.name)
  end

  # Extract first paragraph from description, removing markdown noise
  defp sanitize_description(nil), do: nil

  defp sanitize_description(description) do
    description
    |> String.trim()
    # Split on double newlines (paragraph breaks) and take first
    |> String.split(~r/\n\n+/)
    |> List.first()
    # Remove **Type**: prefix if present (it's redundant with the type badge)
    |> String.replace(~r/^\*\*Type\*\*:\s*\w+\s*\n*/i, "")
    |> String.trim()
  end
end
