defmodule CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummary do
  @moduledoc """
  Provides a comprehensive health overview of the system architecture including:
  - Story coverage: assigned/unassigned component counts
  - Context distribution: components grouped by story count (1, 2-6, 7+)
  - Dependency issues: missing references, high fan-out contexts
  - Data quality: duplicate stories and other consistency issues

  This gives LLMs and developers a quick health assessment of the entire architecture.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame) do
      all_components = Components.list_components_with_dependencies(scope)
      health_summary = analyze_health(all_components, scope)
      {:reply, health_response(health_summary), frame}
    else
      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp analyze_health(components, scope) do
    %{
      story_coverage: analyze_story_coverage(components),
      context_distribution: analyze_context_distribution(components),
      dependency_issues: analyze_dependency_issues(components, scope),
      overall_score: calculate_overall_score(components, scope)
    }
  end

  defp analyze_story_coverage(components) do
    total_components = length(components)

    # Components with stories (entry points)
    entry_components =
      Enum.filter(components, fn c ->
        (c.stories || []) != []
      end)

    # Get all component IDs that are dependencies of entry points
    dependency_ids =
      entry_components
      |> Enum.flat_map(fn c -> get_all_dependency_ids(c, components) end)
      |> MapSet.new()

    # Categorize all components
    entry_count = length(entry_components)

    dependency_count =
      Enum.count(components, fn c ->
        (c.stories || []) == [] and MapSet.member?(dependency_ids, c.id)
      end)

    orphaned_count = total_components - entry_count - dependency_count

    # Coverage based on entry points vs components that should have stories (entry + orphaned)
    components_needing_stories = entry_count + orphaned_count

    story_coverage =
      if components_needing_stories > 0 do
        Float.round(entry_count / components_needing_stories * 100, 1)
      else
        100.0
      end

    # Health based on orphaned components (the real issue)
    orphaned_percentage =
      if total_components > 0 do
        Float.round(orphaned_count / total_components * 100, 1)
      else
        0.0
      end

    %{
      total_components: total_components,
      entry_components: entry_count,
      dependency_components: dependency_count,
      orphaned_components: orphaned_count,
      story_coverage_percentage: story_coverage,
      orphaned_percentage: orphaned_percentage,
      health_status: coverage_health_status_by_orphans(orphaned_percentage)
    }
  end

  defp get_all_dependency_ids(component, all_components, visited \\ MapSet.new()) do
    if MapSet.member?(visited, component.id) do
      []
    else
      visited = MapSet.put(visited, component.id)

      direct_deps =
        Enum.map(component.outgoing_dependencies || [], fn dep ->
          dep.target_component.id
        end)

      indirect_deps =
        (component.outgoing_dependencies || [])
        |> Enum.flat_map(&indirect_dep_ids(&1, all_components, visited))

      direct_deps ++ indirect_deps
    end
  end

  defp indirect_dep_ids(dep, all_components, visited) do
    case Enum.find(all_components, &(&1.id == dep.target_component.id)) do
      nil -> []
      dep_component -> get_all_dependency_ids(dep_component, all_components, visited)
    end
  end

  defp analyze_context_distribution(components) do
    # Get component categorization from story coverage analysis
    coverage_analysis = analyze_story_coverage(components)

    # Get raw story count distribution
    story_distribution =
      components
      |> Enum.map(fn c -> length(c.stories || []) end)
      |> Enum.frequencies()
      |> Enum.into(%{}, fn {count, freq} -> {Integer.to_string(count), freq} end)

    # Calculate health based on distribution patterns
    high_story_components =
      Enum.sum(
        story_distribution
        |> Enum.filter(fn {count_str, _freq} -> String.to_integer(count_str) >= 7 end)
        |> Enum.map(fn {_count, freq} -> freq end)
      )

    %{
      story_distribution: story_distribution,
      orphaned_components: coverage_analysis.orphaned_components,
      dependency_components: coverage_analysis.dependency_components,
      distribution_health: distribution_health_status(high_story_components)
    }
  end

  defp analyze_dependency_issues(components, scope) do
    all_component_ids = MapSet.new(components, & &1.id)

    missing_refs = find_missing_references(components, all_component_ids)
    high_fan_out = find_high_fan_out_components(components)

    circular_dependencies =
      case Components.validate_dependency_graph(scope) do
        {:error, cycles} -> cycles
        :ok -> []
      end

    %{
      missing_references: missing_refs,
      high_fan_out_components: high_fan_out,
      circular_dependencies: circular_dependencies,
      dependency_health:
        dependency_health_status(missing_refs, high_fan_out, circular_dependencies)
    }
  end

  defp find_missing_references(components, all_component_ids) do
    components
    |> Enum.flat_map(fn component ->
      Enum.filter(component.outgoing_dependencies || [], fn dep ->
        not MapSet.member?(all_component_ids, dep.target_component.id)
      end)
      |> Enum.map(fn dep ->
        %{
          component_id: component.id,
          component_name: component.name,
          missing_target_id: dep.target_component.id,
          missing_target_name: dep.target_component.name
        }
      end)
    end)
  end

  defp find_high_fan_out_components(components) do
    components
    |> Enum.filter(fn c -> length(c.outgoing_dependencies || []) > 5 end)
    |> Enum.map(fn c ->
      %{
        id: c.id,
        name: c.name,
        dependency_count: length(c.outgoing_dependencies || []),
        dependencies:
          Enum.map(c.outgoing_dependencies || [], fn dep ->
            %{id: dep.target_component.id, name: dep.target_component.name}
          end)
      }
    end)
  end

  defp calculate_overall_score(components, scope) do
    coverage_score = coverage_score(components)
    dependency_score = dependency_score(components, scope)

    overall = Float.round((coverage_score + dependency_score) / 2, 1)

    %{
      overall_score: overall,
      coverage_score: coverage_score,
      dependency_score: dependency_score,
      health_level: score_to_health_level(overall)
    }
  end

  defp coverage_score(components) do
    coverage_analysis = analyze_story_coverage(components)
    # Score based on lack of orphaned components (inverted orphaned percentage)
    100.0 - coverage_analysis.orphaned_percentage
  end

  defp dependency_score(components, scope) do
    all_component_ids = MapSet.new(components, & &1.id)

    missing_refs = find_missing_references(components, all_component_ids)
    high_fan_out = find_high_fan_out_components(components)

    circular_penalty =
      case Components.validate_dependency_graph(scope) do
        {:error, _cycles} -> 20
        :ok -> 0
      end

    penalty = length(missing_refs) * 10 + length(high_fan_out) * 5 + circular_penalty
    max(0.0, 100.0 - penalty)
  end

  # Health status helpers
  defp coverage_health_status_by_orphans(orphaned_percentage) when orphaned_percentage == 0,
    do: :excellent

  defp coverage_health_status_by_orphans(orphaned_percentage) when orphaned_percentage <= 10,
    do: :good

  defp coverage_health_status_by_orphans(orphaned_percentage) when orphaned_percentage <= 25,
    do: :fair

  defp coverage_health_status_by_orphans(_), do: :poor

  defp distribution_health_status(high_story_components) do
    cond do
      high_story_components > 3 -> :concerning
      high_story_components > 1 -> :fair
      true -> :good
    end
  end

  defp dependency_health_status(missing_refs, high_fan_out, circular_deps) do
    issues = length(missing_refs) + length(high_fan_out) + length(circular_deps)

    cond do
      issues == 0 -> :excellent
      issues <= 2 -> :good
      issues <= 5 -> :fair
      true -> :poor
    end
  end

  defp score_to_health_level(score) when score >= 85, do: :excellent
  defp score_to_health_level(score) when score >= 70, do: :good
  defp score_to_health_level(score) when score >= 50, do: :fair
  defp score_to_health_level(_), do: :poor

  defp health_response(health_summary) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.json(%{
      architecture_health: health_summary
    })
  end
end
