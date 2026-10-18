defmodule CodeMySpec.Components.Tools.ContextStatistics do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "context_statistics"

  @impl true
  def description do
    """
    Provides statistical overview of each component context including:
    - Story count per component
    - Dependency in/out counts per component
    - Results sorted by story count or dependency count
    - Raw numbers for LLM analysis
    """
  end

  @impl true
  def params do
    %{sort_by: {:string, {:default, "story_count"}}}
  end

  @impl true
  def call(params, context) do
    sort_by = Map.get(params, :sort_by, "story_count")

    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        components = Components.list_components_with_dependencies(scope)
        statistics = build_statistics(components, sort_by)
        statistics_response(statistics)

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  end

  defp build_statistics(components, sort_by) do
    component_stats =
      components
      |> Enum.map(&component_statistics/1)
      |> sort_statistics(sort_by)

    %{
      component_statistics: component_stats,
      summary: build_summary(component_stats),
      sort_criteria: sort_by
    }
  end

  defp component_statistics(component) do
    story_count = length(component.stories || [])
    outgoing_count = length(component.outgoing_dependencies || [])
    incoming_count = length(component.incoming_dependencies || [])
    total_dependency_count = outgoing_count + incoming_count

    %{
      component: %{
        id: component.id,
        name: component.name,
        type: component.type,
        module_name: component.module_name
      },
      story_count: story_count,
      dependency_counts: %{
        outgoing: outgoing_count,
        incoming: incoming_count,
        total: total_dependency_count
      }
    }
  end

  defp sort_statistics(stats, "story_count") do
    Enum.sort_by(stats, & &1.story_count, :desc)
  end

  defp sort_statistics(stats, "dependency_count") do
    Enum.sort_by(stats, &get_in(&1, [:dependency_counts, :total]), :desc)
  end

  defp build_summary(component_stats) do
    total_components = length(component_stats)
    total_stories = Enum.sum(Enum.map(component_stats, & &1.story_count))

    total_dependencies =
      Enum.sum(Enum.map(component_stats, &get_in(&1, [:dependency_counts, :total])))

    components_with_stories = Enum.count(component_stats, fn stat -> stat.story_count > 0 end)

    %{
      total_components: total_components,
      total_stories: total_stories,
      total_dependencies: total_dependencies,
      components_with_stories: components_with_stories
    }
  end

  defp statistics_response(statistics) do
    {:ok, JSON.encode!(statistics)}
  end
end
