defmodule CodeMySpec.Architecture.ProposalProjector do
  @moduledoc """
  Projects current DB state into proposal markdown format.

  This is the inverse of `Proposal.from_markdown/2` — it reads components,
  dependencies, and story links from the database and formats them as the
  proposal markdown document that agents can edit.
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @surface_types ~w(liveview live_context controller channel liveview_component plug)

  @doc """
  Projects the current architecture state into proposal markdown.

  Reads all components, dependencies, and story links from the DB
  and formats them into the proposal document format.
  """
  @spec project(Scope.t()) :: String.t()
  def project(%Scope{} = scope) do
    components = Components.list_components_with_dependencies(scope)
    stories_by_component = build_stories_map(scope, components)

    {contexts, surface_components} = partition_components(components)

    sections = [
      project_contexts(contexts, stories_by_component),
      project_surface_components(surface_components, stories_by_component),
      project_dependencies(components)
    ]

    "# Architecture Proposal\n\n" <> Enum.join(sections, "\n")
  end

  @doc """
  Returns a summary of what changed since the last proposal.

  Compares current DB state against story assignments to identify:
  - New stories without surface component assignments
  - Components with no stories or dependencies (orphaned)
  """
  @spec change_summary(Scope.t()) :: String.t()
  def change_summary(%Scope{} = scope) do
    unsatisfied = Stories.list_unsatisfied_stories(scope)
    orphaned = Components.list_orphaned_contexts(scope)

    parts = []

    parts =
      if unsatisfied != [] do
        story_list =
          Enum.map_join(unsatisfied, "\n", fn s -> "  - Story #{s.id}: #{s.title}" end)

        parts ++ ["**#{length(unsatisfied)} stories without surface components:**\n#{story_list}"]
      else
        parts ++ ["All stories are mapped to surface components."]
      end

    parts =
      if orphaned != [] do
        orphan_list =
          Enum.map_join(orphaned, "\n", fn c -> "  - #{c.module_name}" end)

        parts ++
          ["**#{length(orphaned)} orphaned contexts** (no stories, not depended on):\n#{orphan_list}"]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  # Private

  defp build_stories_map(scope, components) do
    components
    |> Enum.reduce(%{}, fn component, acc ->
      stories = Stories.list_component_stories(scope, component.id)
      Map.put(acc, component.id, stories)
    end)
  end

  defp partition_components(components) do
    # Top-level components (no parent) split into contexts vs surface
    {top_level, children} =
      Enum.split_with(components, fn c -> is_nil(c.parent_component_id) end)

    children_by_parent = Enum.group_by(children, & &1.parent_component_id)

    # Only actual contexts go in the Contexts section.
    # Surface types go in Surface Components.
    # Other top-level modules (plugs, hooks, utility modules) are excluded —
    # they're infrastructure, not architecture components.
    {contexts, non_contexts} =
      Enum.split_with(top_level, fn c -> c.type == "context" end)

    surface = Enum.filter(non_contexts, fn c -> c.type in @surface_types end)

    # Attach children to their parents
    contexts = Enum.map(contexts, &attach_children(&1, children_by_parent))
    surface = Enum.map(surface, &attach_children(&1, children_by_parent))

    {Enum.sort_by(contexts, & &1.module_name),
     Enum.sort_by(surface, & &1.module_name)}
  end

  defp attach_children(%Component{} = component, children_by_parent) do
    children =
      Map.get(children_by_parent, component.id, [])
      |> Enum.sort_by(& &1.module_name)

    %{component | child_components: children}
  end

  defp project_contexts(contexts, stories_by_component) do
    if Enum.empty?(contexts) do
      "## Contexts\n"
    else
      header = "## Contexts\n"

      body =
        contexts
        |> Enum.map_join("\n", &format_context(&1, stories_by_component))

      header <> "\n" <> body
    end
  end

  defp format_context(context, stories_by_component) do
    lines = ["### #{context.module_name}\n"]

    lines = lines ++ ["- **Type:** #{context.type}"]

    lines =
      if context.description && context.description != "" do
        lines ++ ["- **Description:** #{context.description}"]
      else
        lines
      end

    children = context.child_components || []

    lines =
      if children != [] do
        child_lines =
          children
          |> Enum.map(&format_context_child(&1, stories_by_component))

        lines ++ ["\n#### Children\n"] ++ child_lines
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n"
  end

  defp format_context_child(child, _stories_by_component) do
    desc = if child.description && child.description != "", do: ": #{child.description}", else: ""
    "- #{child.module_name} (#{child.type})#{desc}"
  end

  defp project_surface_components(surface_components, stories_by_component) do
    if Enum.empty?(surface_components) do
      "## Surface Components\n"
    else
      header = "## Surface Components\n"

      body =
        surface_components
        |> Enum.map_join("\n", &format_surface_component(&1, stories_by_component))

      header <> "\n" <> body
    end
  end

  defp format_surface_component(component, stories_by_component) do
    lines = ["### #{component.module_name}\n"]

    lines = lines ++ ["- **Type:** #{component.type}"]

    lines =
      if component.description && component.description != "" do
        lines ++ ["- **Description:** #{component.description}"]
      else
        lines
      end

    # Story IDs from the component itself
    own_stories = Map.get(stories_by_component, component.id, [])
    children = component.child_components || []

    child_stories =
      children
      |> Enum.flat_map(fn child -> Map.get(stories_by_component, child.id, []) end)

    all_story_ids =
      (own_stories ++ child_stories)
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()

    lines =
      if all_story_ids != [] do
        lines ++ ["- **Stories:** #{Enum.join(all_story_ids, ", ")}"]
      else
        lines
      end

    lines =
      if children != [] do
        child_lines =
          children
          |> Enum.map(&format_surface_child(&1, stories_by_component))

        lines ++ ["\n#### Children\n"] ++ child_lines
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n"
  end

  defp format_surface_child(child, stories_by_component) do
    stories = Map.get(stories_by_component, child.id, [])
    story_part = if stories != [], do: " [Stories: #{Enum.map_join(stories, ", ", & &1.id)}]", else: ""
    desc = if child.description && child.description != "", do: ": #{child.description}", else: ""
    "- #{child.module_name} (#{child.type})#{story_part}#{desc}"
  end

  defp project_dependencies(components) do
    deps =
      components
      |> Enum.flat_map(&dep_lines_for(&1, components))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> Enum.uniq()

    if Enum.empty?(deps) do
      "## Dependencies\n"
    else
      "## Dependencies\n\n" <> Enum.join(deps, "\n") <> "\n"
    end
  end

  defp dep_lines_for(component, components) do
    outgoing = component.outgoing_dependencies || []
    Enum.map(outgoing, &dep_line(component, &1, components))
  end

  defp dep_line(component, dep, components) do
    case Enum.find(components, &(&1.id == dep.target_component_id)) do
      nil -> nil
      target -> "- #{component.module_name} -> #{target.module_name}"
    end
  end
end
