defmodule CodeMySpec.McpServers.Components.Tools.ShowArchitecture do
  @moduledoc """
  Shows the complete system architecture with comprehensive details including:
  - Full dependency graph with component relationships and types
  - All stories associated with each component
  - Architecture layers organized by dependency depth
  - Detailed component information and metrics

  This provides LLMs with a complete picture of the system architecture,
  showing which components satisfy which stories and how components depend on each other.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      architecture = Components.show_architecture(scope)
      {:reply, architecture_response(architecture), frame}
    else
      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp architecture_response(architecture) do
    Hermes.Server.Response.tool()
    |> Hermes.Server.Response.json(%{
      architecture: %{
        overview: architecture_overview(architecture),
        components: Enum.map(architecture, &architecture_entry/1),
        dependency_graph: build_dependency_graph(architecture)
      }
    })
  end

  defp architecture_overview(architecture) do
    total_components = length(architecture)

    components_with_stories =
      Enum.count(architecture, fn %{component: c} ->
        length(c.stories || []) > 0
      end)

    total_dependencies =
      Enum.sum(
        Enum.map(architecture, fn %{component: c} ->
          length(c.outgoing_dependencies || [])
        end)
      )

    %{
      total_components: total_components,
      components_with_stories: components_with_stories,
      total_dependencies: total_dependencies,
      architecture_layers: group_by_depth(architecture)
    }
  end

  defp group_by_depth(architecture) do
    architecture
    |> Enum.group_by(& &1.depth)
    |> Enum.map(fn {depth, components} ->
      %{
        depth: depth,
        layer_name: layer_name_for_depth(depth),
        component_count: length(components),
        component_names: Enum.map(components, fn %{component: c} -> c.name end)
      }
    end)
    |> Enum.sort_by(& &1.depth)
  end

  defp layer_name_for_depth(0), do: "Entry Points (Components with Stories)"
  defp layer_name_for_depth(depth), do: "Dependency Layer #{depth}"

  defp architecture_entry(%{component: component, depth: depth}) do
    %{
      component: detailed_component_info(component),
      depth: depth,
      layer: layer_name_for_depth(depth)
    }
  end

  defp detailed_component_info(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description,
      stories: format_stories(component.stories || []),
      dependencies: format_dependencies(component.outgoing_dependencies || []),
      metrics: %{
        story_count: length(component.stories || []),
        dependency_count: length(component.outgoing_dependencies || []),
        has_stories: length(component.stories || []) > 0
      }
    }
  end

  defp format_stories(stories) do
    Enum.map(stories, fn story ->
      %{
        id: story.id,
        title: story.title,
        description: story.description,
        status: story.status,
        acceptance_criteria: criteria_descriptions(story)
      }
    end)
  end

  defp format_dependencies(dependencies) do
    Enum.map(dependencies, fn dep ->
      %{
        id: dep.id,
        target: %{
          id: dep.target_component.id,
          name: dep.target_component.name,
          module_name: dep.target_component.module_name,
          type: dep.target_component.type
        }
      }
    end)
  end

  defp build_dependency_graph(architecture) do
    all_relationships =
      architecture
      |> Enum.flat_map(fn %{component: component} ->
        Enum.map(component.outgoing_dependencies || [], fn dep ->
          %{
            from: %{id: component.id, name: component.name, module_name: component.module_name},
            to: %{
              id: dep.target_component.id,
              name: dep.target_component.name,
              module_name: dep.target_component.module_name
            },
            dependency_id: dep.id
          }
        end)
      end)

    %{
      relationships: all_relationships,
      summary: %{
        total_relationships: length(all_relationships)
      }
    }
  end

  defp criteria_descriptions(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map(criteria, & &1.description)

      _ ->
        story.acceptance_criteria || []
    end
  end
end
