defmodule CodeMySpec.Architecture do
  @moduledoc """
  A coordination context that generates and maintains text-based architectural views for AI agent consumption.

  Provides projectors that create documentation artifacts (component hierarchies,
  namespace trees) written to the repository and synchronized with current project state during full syncs.
  """

  alias CodeMySpec.Architecture.{MermaidProjector, NamespaceProjector, OverviewProjector}
  alias CodeMySpec.Components
  alias CodeMySpec.Components.{Component, ComponentRepository}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  # Delegate projector functions
  defdelegate generate_overview(components), to: OverviewProjector, as: :project
  defdelegate generate_namespace_hierarchy(components), to: NamespaceProjector, as: :project
  defdelegate generate_mermaid(components), to: MermaidProjector, as: :project

  @doc """
  Returns a structured summary of architecture metrics for programmatic use.

  ## Examples

      iex> get_architecture_summary(scope)
      %{
        context_count: 5,
        component_count: 42,
        dependency_count: 18,
        orphaned_count: 1,
        max_depth: 4,
        circular_dependencies: false,
        circular_dependency_count: 0
      }

  """
  @spec get_architecture_summary(Scope.t()) :: %{
          context_count: non_neg_integer(),
          component_count: non_neg_integer(),
          dependency_count: non_neg_integer(),
          orphaned_count: non_neg_integer(),
          max_depth: non_neg_integer(),
          circular_dependencies: boolean(),
          circular_dependency_count: non_neg_integer()
        }
  def get_architecture_summary(%Scope{} = scope) do
    components = Components.list_components_with_dependencies(scope)
    contexts = Components.list_contexts(scope)
    dependencies = Components.list_dependencies(scope)
    orphaned = list_orphaned_contexts(scope)
    cycles = circular_dependencies(scope)

    %{
      context_count: length(contexts),
      component_count: length(components),
      dependency_count: length(dependencies),
      orphaned_count: length(orphaned),
      max_depth: calculate_max_namespace_depth(components),
      circular_dependencies: cycles != [],
      circular_dependency_count: length(cycles)
    }
  end

  defp calculate_max_namespace_depth(components) do
    components
    |> Enum.map(fn component ->
      component.module_name
      |> String.split(".")
      |> length()
    end)
    |> Enum.max(fn -> 0 end)
  end

  # `73ff202b`: the count went from 4 to 21 without anyone noticing, because
  # every surface that had it reduced it to a boolean on the way out. This one
  # is called "a structured summary of architecture metrics" and a metric with a
  # magnitude should not be reported as yes/no — `validate_dependency_graph`
  # hands back the cycles themselves and they were being thrown away one line
  # later.
  #
  # Reporting only. Nothing gates on the count, deliberately: at 21 a gate would
  # wedge every agent, and which edge of each pair is the wrong one is an
  # architecture decision per cycle.
  defp circular_dependencies(scope) do
    case Components.validate_dependency_graph(scope) do
      :ok -> []
      {:error, cycles} -> cycles
    end
  end

  @doc """
  Returns contexts that have no stories and are not dependencies of any entry points.

  Entry points are defined as components that have associated stories.
  """
  @spec list_orphaned_contexts(Scope.t()) :: [Component.t()]
  def list_orphaned_contexts(%Scope{} = scope) do
    Components.list_orphaned_contexts(scope)
  end

  @doc """
  Analyzes the impact of modifying a component by tracing all dependents.

  ## Examples

      iex> get_component_impact(scope, component_id)
      %{
        component: %Component{},
        direct_dependents: [%Component{}],
        transitive_dependents: [%Component{}, %Component{}],
        affected_contexts: [%Component{}]
      }

  """
  @spec get_component_impact(Scope.t(), String.t()) :: %{
          component: Component.t(),
          direct_dependents: [Component.t()],
          transitive_dependents: [Component.t()],
          affected_contexts: [Component.t()]
        }
  def get_component_impact(%Scope{} = scope, component_id) do
    all_components = Components.list_components_with_dependencies(scope)
    component = ComponentRepository.get_component_with_dependencies(scope, component_id)

    direct_dependents = get_direct_dependents(component, all_components)

    transitive_dependents =
      get_transitive_dependents(direct_dependents, all_components, MapSet.new([component_id]))

    all_affected = [component] ++ direct_dependents ++ transitive_dependents
    affected_contexts = get_affected_contexts(all_affected, all_components)

    %{
      component: component,
      direct_dependents: direct_dependents,
      transitive_dependents: transitive_dependents,
      affected_contexts: affected_contexts
    }
  end

  defp get_direct_dependents(component, all_components) do
    dependent_ids =
      (component.incoming_dependencies || [])
      |> Enum.map(& &1.source_component_id)
      |> MapSet.new()

    all_components
    |> Enum.filter(&MapSet.member?(dependent_ids, &1.id))
  end

  defp get_transitive_dependents(direct_dependents, all_components, visited) do
    new_dependents =
      direct_dependents
      |> Enum.flat_map(fn dependent ->
        if MapSet.member?(visited, dependent.id) do
          []
        else
          get_direct_dependents(dependent, all_components)
        end
      end)
      |> Enum.uniq_by(& &1.id)

    new_visited =
      Enum.reduce(direct_dependents, visited, fn dep, acc -> MapSet.put(acc, dep.id) end)

    case new_dependents do
      [] ->
        []

      dependents ->
        dependents ++ get_transitive_dependents(dependents, all_components, new_visited)
    end
  end

  defp get_affected_contexts(components, all_components) do
    # Get parent context IDs from components
    context_ids =
      components
      |> Enum.flat_map(fn component ->
        case component.parent_component_id do
          nil -> [component.id]
          parent_id -> [parent_id]
        end
      end)
      |> Enum.uniq()
      |> MapSet.new()

    # Find the actual context components
    all_components
    |> Enum.filter(fn component ->
      MapSet.member?(context_ids, component.id) && component.type == "context"
    end)
  end

  @doc """
  Generates a detailed markdown view of a component and its full dependency tree.

  Accepts either a single component ID/module name or a list of them.

  ## Examples

      iex> generate_component_view(scope, component_id)
      "# MyApp.Users\\n\\nUser management context\\n\\n## Dependencies\\n..."

      iex> generate_component_view(scope, [id1, id2])
      "# MyApp.Users\\n...\\n\\n# MyApp.Accounts\\n..."

  """
  @spec generate_component_view(Scope.t(), String.t() | [String.t()]) :: String.t()
  def generate_component_view(%Scope{} = scope, component_ids) when is_list(component_ids) do
    Enum.map_join(component_ids, "\n\n---\n\n", &generate_single_component_view(scope, &1))
  end

  def generate_component_view(%Scope{} = scope, component_id) when is_binary(component_id) do
    generate_single_component_view(scope, component_id)
  end

  defp generate_single_component_view(scope, component_id_or_name) do
    component = fetch_component(scope, component_id_or_name)
    all_components = Components.list_components_with_dependencies(scope)

    dependencies = collect_all_dependencies(component, all_components)

    format_component_view(component, dependencies)
  end

  defp fetch_component(scope, id_or_name) do
    # Check if it's a valid UUID format
    if uuid?(id_or_name) do
      # Try as UUID first
      ComponentRepository.get_component_with_dependencies(scope, id_or_name)
    else
      # It's a module name - fetch by module name and preload dependencies
      case Components.get_component_by_module_name(scope, id_or_name) do
        nil ->
          nil

        component ->
          # Preload dependencies manually
          Repo.preload(component, [
            :dependencies,
            :dependents,
            :outgoing_dependencies,
            :incoming_dependencies
          ])
      end
    end
  end

  defp uuid?(string) do
    case UUID.info(string) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp collect_all_dependencies(component, all_components) do
    collect_dependencies_with_depth(component, all_components, 0, MapSet.new())
    |> Enum.sort_by(fn {_comp, depth} -> depth end)
  end

  defp collect_dependencies_with_depth(component, all_components, depth, visited) do
    if MapSet.member?(visited, component.id) do
      []
    else
      visited = MapSet.put(visited, component.id)

      direct_deps =
        (component.outgoing_dependencies || [])
        |> Enum.map(fn dep ->
          target = Enum.find(all_components, fn c -> c.id == dep.target_component_id end)
          {target, depth + 1}
        end)
        |> Enum.reject(fn {target, _} -> is_nil(target) end)

      transitive_deps =
        direct_deps
        |> Enum.flat_map(fn {dep_component, new_depth} ->
          collect_dependencies_with_depth(dep_component, all_components, new_depth, visited)
        end)

      direct_deps ++ transitive_deps
    end
  end

  defp format_component_view(component, dependencies) do
    sections = [
      format_header(component),
      format_description(component),
      format_dependencies_section(dependencies)
    ]

    sections
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_header(component) do
    "# #{component.name}\n\n**Type:** #{component.type}\n**Module:** #{component.module_name}"
  end

  defp format_description(component) do
    case component.description do
      nil -> ""
      "" -> ""
      desc -> desc
    end
  end

  defp format_dependencies_section([]), do: ""

  defp format_dependencies_section(dependencies) do
    # Group by depth
    grouped =
      dependencies
      |> Enum.group_by(fn {_comp, depth} -> depth end)
      |> Enum.sort_by(fn {depth, _} -> depth end)

    # Deduplicate - only show each component once at its shallowest depth
    seen = MapSet.new()

    formatted_deps = build_formatted_dependencies(grouped, seen)

    case formatted_deps do
      [] -> ""
      lines -> "## Dependencies\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp build_formatted_dependencies(grouped, seen) do
    {formatted_deps, _} =
      Enum.reduce(grouped, {[], seen}, fn {depth, deps}, {acc, seen_set} ->
        {new_lines, new_seen} = process_depth_group(deps, depth, seen_set)
        {acc ++ new_lines, new_seen}
      end)

    formatted_deps
  end

  defp process_depth_group(deps, depth, seen_set) do
    Enum.reduce(deps, {[], seen_set}, fn {comp, _}, {lines, seen_inner} ->
      if MapSet.member?(seen_inner, comp.id) do
        {lines, seen_inner}
      else
        line = format_dependency_line(comp, depth)
        {lines ++ [line], MapSet.put(seen_inner, comp.id)}
      end
    end)
  end

  defp format_dependency_line(component, depth) do
    indent = String.duplicate("  ", depth - 1)
    prefix = if depth == 1, do: "- ", else: "#{indent}- "

    description = if component.description, do: " - #{component.description}", else: ""

    "#{prefix}**#{component.name}** (#{component.module_name})#{description}"
  end
end
