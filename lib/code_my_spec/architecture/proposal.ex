defmodule CodeMySpec.Architecture.Proposal do
  @moduledoc """
  Represents an architecture proposal for a greenfield project.

  A proposal contains:
  - Bounded contexts with their child components
  - Surface components (controllers, LiveViews)
  - Story mappings

  Proposals are ephemeral - they exist only during a design session.
  Use `validate/1` to check for issues before `execute/2`.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Stories

  defstruct [
    :app_name,
    contexts: [],
    surface_components: [],
    dependencies: [],
    unmapped_story_ids: []
  ]

  @type t :: %__MODULE__{
          app_name: String.t(),
          contexts: [context()],
          surface_components: [component()],
          dependencies: [dependency()],
          unmapped_story_ids: [integer()]
        }

  @type context :: %{
          name: String.t(),
          description: String.t(),
          children: [component()],
          story_ids: [integer()]
        }

  @type component :: %{
          name: String.t(),
          type: String.t(),
          description: String.t(),
          story_ids: [integer()]
        }

  @type dependency :: %{
          from: String.t(),
          to: String.t()
        }

  @type validation_error :: %{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @doc """
  Creates a new proposal from a map of attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      app_name: get_attr(attrs, :app_name, "App"),
      contexts: normalize_contexts(get_attr(attrs, :contexts, [])),
      surface_components: normalize_components(get_attr(attrs, :surface_components, [])),
      dependencies: normalize_dependencies(get_attr(attrs, :dependencies, [])),
      unmapped_story_ids: get_attr(attrs, :unmapped_story_ids, [])
    }
  end

  @doc """
  Creates a proposal from a parsed document.

  Uses the Documents system to parse markdown and returns a Proposal struct.

  Options:
  - `:app_name` - The application module name (e.g., "MetricFlow"). Required.
  """
  @spec from_markdown(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_markdown(content, opts \\ []) do
    alias CodeMySpec.Documents

    app_name = Keyword.get(opts, :app_name) || raise "app_name is required for from_markdown/2"

    case Documents.create_dynamic_document(content, "architecture_proposal") do
      {:ok, %{sections: sections}} ->
        # Transform dependencies from strings to maps
        deps =
          (sections["dependencies"] || [])
          |> Enum.map(&parse_dependency_string/1)
          |> Enum.reject(&is_nil/1)

        {:ok,
         new(%{
           app_name: app_name,
           contexts: sections["contexts"] || [],
           surface_components: sections["surface components"] || [],
           dependencies: deps
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_dependency_string(text) when is_binary(text) do
    case Regex.run(~r/(.+?)\s*->\s*(.+)/, text) do
      [_, from, to] -> %{from: String.trim(from), to: String.trim(to)}
      _ -> nil
    end
  end

  defp parse_dependency_string(%{from: _, to: _} = dep), do: dep
  defp parse_dependency_string(_), do: nil

  @doc """
  Validates a proposal for issues.

  Returns `{:ok, proposal}` if valid, or `{:error, errors}` with a list of issues.
  """
  @spec validate(t(), keyword()) :: {:ok, t()} | {:error, [validation_error()]}
  def validate(%__MODULE__{} = proposal, opts \\ []) do
    all_story_ids = Keyword.get(opts, :story_ids, [])
    known_db_components = Keyword.get(opts, :db_components, [])

    errors =
      []
      |> check_naming_conventions(proposal)
      |> check_naming_hierarchy(proposal)
      |> check_invalid_types(proposal)
      |> check_story_surface_mapping(proposal, all_story_ids)
      |> check_dependency_cycles(proposal)
      |> check_duplicate_names(proposal)
      |> check_dependency_resolution(proposal, known_db_components)

    if errors == [] do
      {:ok, proposal}
    else
      {:error, errors}
    end
  end

  @doc """
  Executes the proposal, creating all specs and linking stories.

  Options:
  - `:dry_run` - If true, returns what would be created without making changes
  """
  @spec execute(t(), Scope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%__MODULE__{} = proposal, scope, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      {:ok, preview_execution(proposal)}
    else
      do_execute(proposal, scope, opts)
    end
  end

  @doc """
  Returns all component definitions from the proposal for creation.
  """
  @spec to_components(t()) :: [map()]
  def to_components(%__MODULE__{} = proposal) do
    # All names are fully-qualified (e.g., "Fuellytics.Verification.Transaction")
    deps_map = build_dependencies_map(proposal.dependencies)

    context_components =
      proposal.contexts
      |> Enum.flat_map(fn ctx ->
        parent = %{
          module_name: ctx.name,
          type: "context",
          description: ctx.description,
          story_ids: ctx.story_ids,
          dependencies: Map.get(deps_map, ctx.name, [])
        }

        children =
          ctx.children
          |> Enum.map(fn child ->
            # Child names are already fully qualified (e.g., "Fuellytics.Verification.Transaction")
            %{
              module_name: child.name,
              type: child.type,
              description: child.description,
              parent_module: ctx.name,
              story_ids: child.story_ids,
              dependencies: Map.get(deps_map, child.name, [])
            }
          end)

        [parent | children]
      end)

    surface =
      proposal.surface_components
      |> Enum.flat_map(fn comp ->
        parent = %{
          module_name: comp.name,
          type: comp.type,
          description: comp.description,
          story_ids: comp.story_ids,
          dependencies: Map.get(deps_map, comp.name, [])
        }

        children =
          comp
          |> Map.get(:children, [])
          |> Enum.map(fn child ->
            %{
              module_name: child.name,
              type: child.type,
              description: child.description,
              parent_module: comp.name,
              story_ids: child.story_ids,
              dependencies: Map.get(deps_map, child.name, [])
            }
          end)

        [parent | children]
      end)

    context_components ++ surface
  end

  defp build_dependencies_map(dependencies) do
    dependencies
    |> Enum.reduce(%{}, fn dep, acc ->
      Map.update(acc, dep.from, [dep.to], &[dep.to | &1])
    end)
  end

  # Private functions

  # Lookup a key by atom or string, with a default fallback
  defp get_attr(map, key, default \\ nil) do
    map[key] || map[to_string(key)] || default
  end

  defp normalize_name(map) do
    name = get_attr(map, :name) || get_attr(map, :module_name)
    if is_binary(name), do: String.trim(name), else: name
  end

  defp normalize_contexts(contexts) do
    Enum.map(contexts, fn ctx ->
      %{
        name: normalize_name(ctx),
        description: get_attr(ctx, :description, ""),
        children: normalize_components(get_attr(ctx, :children, [])),
        story_ids: get_attr(ctx, :story_ids, [])
      }
    end)
  end

  defp normalize_components(components) do
    Enum.map(components, &normalize_component/1)
  end

  defp normalize_component(comp) do
    base = %{
      name: normalize_name(comp),
      type: get_attr(comp, :type),
      description: get_attr(comp, :description, ""),
      story_ids: get_attr(comp, :story_ids, [])
    }

    children = get_attr(comp, :children)

    if children && children != [] do
      Map.put(base, :children, normalize_components(children))
    else
      base
    end
  end

  defp normalize_dependencies(deps) do
    Enum.map(deps, fn dep ->
      %{
        from: get_attr(dep, :from),
        to: get_attr(dep, :to)
      }
    end)
  end

  defp check_naming_conventions(errors, proposal) do
    invalid_contexts =
      proposal.contexts
      |> Enum.reject(fn ctx -> valid_module_name?(ctx.name) end)
      |> Enum.map(& &1.name)

    invalid_components =
      proposal.surface_components
      |> Enum.reject(fn comp -> valid_module_name?(comp.name) end)
      |> Enum.map(& &1.name)

    invalid = invalid_contexts ++ invalid_components

    if invalid == [] do
      errors
    else
      [
        %{
          type: :invalid_naming,
          message: "Invalid module names found",
          details: %{names: invalid}
        }
        | errors
      ]
    end
  end

  defp check_naming_hierarchy(errors, proposal) do
    # Camelize app_name since it may be snake_case from project config
    # but module names use PascalCase (e.g., "metric_flow" -> "MetricFlow")
    app_name = Macro.camelize(proposal.app_name)
    app_web = "#{app_name}Web"

    # Contexts must start with app_name
    invalid_contexts =
      proposal.contexts
      |> Enum.reject(fn ctx -> String.starts_with?(ctx.name, "#{app_name}.") end)
      |> Enum.map(& &1.name)

    # Surface components must start with app_name + "Web"
    invalid_surfaces =
      proposal.surface_components
      |> Enum.reject(fn comp -> String.starts_with?(comp.name, "#{app_web}.") end)
      |> Enum.map(& &1.name)

    # Children must start with their parent context name
    invalid_children =
      proposal.contexts
      |> Enum.flat_map(fn ctx ->
        ctx.children
        |> Enum.reject(fn child -> String.starts_with?(child.name, "#{ctx.name}.") end)
        |> Enum.map(fn child ->
          "#{child.name} (should start with #{ctx.name}.)"
        end)
      end)

    # Surface components with children (live_context) — children must start with parent name
    invalid_surface_children =
      proposal.surface_components
      |> Enum.flat_map(fn comp ->
        comp
        |> Map.get(:children, [])
        |> Enum.reject(fn child -> String.starts_with?(child.name, "#{comp.name}.") end)
        |> Enum.map(fn child ->
          "#{child.name} (should start with #{comp.name}.)"
        end)
      end)

    all_invalid = invalid_contexts ++ invalid_surfaces ++ invalid_children ++ invalid_surface_children

    if all_invalid == [] do
      errors
    else
      messages = []

      messages =
        if invalid_contexts != [],
          do: ["Contexts must start with '#{app_name}.'" | messages],
          else: messages

      messages =
        if invalid_surfaces != [],
          do: ["Surface components must start with '#{app_web}.'" | messages],
          else: messages

      messages =
        if invalid_children != [],
          do: ["Children must start with their parent context name" | messages],
          else: messages

      messages =
        if invalid_surface_children != [],
          do: ["Surface component children must start with their parent name" | messages],
          else: messages

      [
        %{
          type: :invalid_naming_hierarchy,
          message: Enum.join(messages, ". "),
          details: %{
            invalid_contexts: invalid_contexts,
            invalid_surfaces: invalid_surfaces,
            invalid_children: invalid_children,
            invalid_surface_children: invalid_surface_children
          }
        }
        | errors
      ]
    end
  end

  defp check_story_surface_mapping(errors, _proposal, all_story_ids) when all_story_ids == [] do
    errors
  end

  defp check_story_surface_mapping(errors, proposal, all_story_ids) do
    all_linked = collect_all_linked_story_ids(proposal)
    all_ids = MapSet.new(all_story_ids)
    orphans = MapSet.difference(all_ids, all_linked) |> MapSet.to_list()

    if orphans == [] do
      errors
    else
      [
        %{
          type: :stories_missing_surface,
          message: "Each story must be linked to at least one component",
          details: %{story_ids: orphans}
        }
        | errors
      ]
    end
  end

  defp collect_all_linked_story_ids(proposal) do
    surface_ids =
      Enum.flat_map(proposal.surface_components, fn comp ->
        own = Map.get(comp, :story_ids, [])
        children = Map.get(comp, :children, []) |> Enum.flat_map(&Map.get(&1, :story_ids, []))
        own ++ children
      end)

    context_ids =
      Enum.flat_map(proposal.contexts, fn ctx ->
        own = Map.get(ctx, :story_ids, [])
        children = ctx.children |> Enum.flat_map(&Map.get(&1, :story_ids, []))
        own ++ children
      end)

    MapSet.new(surface_ids ++ context_ids)
  end

  @doc """
  Collects non-blocking warnings for a proposal.

  Returns a list of warning strings for surface-preference violations
  (stories whose only links are to non-surface components).
  """
  @spec collect_warnings(t()) :: [String.t()]
  def collect_warnings(%__MODULE__{} = proposal) do
    surface_linked =
      proposal.surface_components
      |> Enum.flat_map(fn comp ->
        own = Map.get(comp, :story_ids, [])
        children = Map.get(comp, :children, []) |> Enum.flat_map(&Map.get(&1, :story_ids, []))
        own ++ children
      end)
      |> MapSet.new()

    non_surface_links =
      Enum.flat_map(proposal.contexts, fn ctx ->
        own = Enum.map(Map.get(ctx, :story_ids, []), fn story_id -> {story_id, ctx.name} end)
        children = Enum.flat_map(ctx.children, &child_story_links/1)
        own ++ children
      end)

    non_surface_links
    |> Enum.reject(fn {story_id, _} -> MapSet.member?(surface_linked, story_id) end)
    |> Enum.map(fn {story_id, component_name} ->
      "Surface preference: story #{story_id} is linked to non-surface component #{component_name}. Surface components (LiveView, Controller, Channel, MCP tool) are preferred."
    end)
  end

  defp check_dependency_cycles(errors, proposal) do
    graph = build_dependency_graph(proposal)
    types = build_component_type_map(proposal)

    cycles =
      graph
      |> find_cycles()
      |> Enum.reject(&schema_only_cycle?(&1, types))

    if cycles == [] do
      errors
    else
      [
        %{
          type: :dependency_cycle,
          message: "Circular dependencies detected",
          details: %{cycles: cycles}
        }
        | errors
      ]
    end
  end

  defp build_component_type_map(proposal) do
    context_entries =
      Enum.flat_map(proposal.contexts, fn ctx ->
        [{ctx.name, "context"} | Enum.map(ctx.children, &{&1.name, &1.type})]
      end)

    surface_entries =
      Enum.flat_map(proposal.surface_components, fn comp ->
        [
          {comp.name, comp.type}
          | Enum.map(Map.get(comp, :children, []), &{&1.name, &1.type})
        ]
      end)

    Map.new(context_entries ++ surface_entries)
  end

  defp schema_only_cycle?(cycle, types) do
    Enum.all?(cycle, fn name -> Map.get(types, name) == "schema" end)
  end

  defp check_dependency_resolution(errors, proposal, db_component_names) do
    proposal_names = collect_all_component_names(proposal)
    known = MapSet.union(MapSet.new(proposal_names), MapSet.new(db_component_names))

    unresolved =
      proposal.dependencies
      |> Enum.reject(fn dep -> MapSet.member?(known, dep.to) end)
      |> Enum.map(fn dep -> "#{dep.from} -> #{dep.to}" end)

    if unresolved == [] do
      errors
    else
      [
        %{
          type: :unresolved_dependency,
          message: "Dependencies reference unknown components",
          details: %{unresolved: unresolved}
        }
        | errors
      ]
    end
  end

  defp collect_all_component_names(proposal) do
    context_names =
      Enum.flat_map(proposal.contexts, fn ctx ->
        [ctx.name | Enum.map(ctx.children, & &1.name)]
      end)

    surface_names =
      Enum.flat_map(proposal.surface_components, fn comp ->
        [comp.name | Enum.map(Map.get(comp, :children, []), & &1.name)]
      end)

    context_names ++ surface_names
  end

  defp check_duplicate_names(errors, proposal) do
    all_names =
      Enum.map(proposal.contexts, & &1.name) ++
        Enum.map(proposal.surface_components, & &1.name) ++
        Enum.flat_map(proposal.contexts, fn ctx ->
          Enum.map(ctx.children, fn child -> "#{ctx.name}.#{child.name}" end)
        end)

    duplicates =
      all_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    if duplicates == [] do
      errors
    else
      [
        %{
          type: :duplicate_names,
          message: "Duplicate component names found",
          details: %{names: duplicates}
        }
        | errors
      ]
    end
  end

  @valid_types ~w(context schema module liveview liveview_component live_context controller component channel plug)

  defp check_invalid_types(errors, proposal) do
    # Collect all types from children and surface components
    child_types =
      proposal.contexts
      |> Enum.flat_map(fn ctx ->
        Enum.map(ctx.children, fn child -> {child.name, child.type} end)
      end)

    surface_types =
      Enum.map(proposal.surface_components, fn comp -> {comp.name, comp.type} end)

    all_typed = child_types ++ surface_types

    invalid =
      all_typed
      |> Enum.reject(fn {_name, type} -> type in @valid_types end)
      |> Enum.map(fn {name, type} -> "#{name} has invalid type '#{type}'" end)

    if invalid == [] do
      errors
    else
      [
        %{
          type: :invalid_type,
          message: "Component types must be one of: #{Enum.join(@valid_types, ", ")}",
          details: %{invalid: invalid}
        }
        | errors
      ]
    end
  end

  defp valid_module_name?(nil), do: false

  defp valid_module_name?(name) do
    Regex.match?(~r/^[A-Z][a-zA-Z0-9]*(\.[A-Z][a-zA-Z0-9]*)*$/, name)
  end

  defp build_dependency_graph(proposal) do
    proposal.dependencies
    |> Enum.reduce(%{}, fn dep, graph ->
      Map.update(graph, dep.from, [dep.to], &[dep.to | &1])
    end)
  end

  defp find_cycles(graph) do
    nodes = Map.keys(graph)

    nodes
    |> Enum.reduce([], fn node, cycles ->
      case dfs_find_cycle(graph, node, node, [node], MapSet.new([node])) do
        nil -> cycles
        cycle -> [cycle | cycles]
      end
    end)
    |> Enum.uniq()
  end

  defp dfs_find_cycle(graph, start, current, path, visited) do
    neighbors = Map.get(graph, current, [])

    Enum.find_value(neighbors, fn neighbor ->
      cond do
        neighbor == start ->
          # Found cycle back to start
          path ++ [neighbor]

        MapSet.member?(visited, neighbor) ->
          nil

        true ->
          dfs_find_cycle(
            graph,
            start,
            neighbor,
            path ++ [neighbor],
            MapSet.put(visited, neighbor)
          )
      end
    end)
  end

  defp preview_execution(proposal) do
    components = to_components(proposal)

    %{
      created_contexts: Enum.count(proposal.contexts),
      created_components: length(components),
      linked_stories: count_linked_stories(proposal),
      components: components
    }
  end

  defp do_execute(proposal, scope, opts) do
    components = to_components(proposal)

    case resolve_env(opts) do
      {:ok, env, owned?} ->
        try do
          do_execute_with_env(proposal, scope, components, env)
        after
          if owned?, do: Environments.destroy(env)
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_env(opts) do
    case Keyword.get(opts, :env) do
      nil ->
        working_dir = Keyword.get(opts, :working_dir, File.cwd!())

        case Environments.create(:cli, working_dir: working_dir) do
          {:ok, env} -> {:ok, env, true}
          {:error, _} = err -> err
        end

      env ->
        {:ok, env, false}
    end
  end

  defp do_execute_with_env(proposal, scope, components, env) do
    pre_existing_db_names = list_db_component_names(scope)

    with {:ok, created_components} <- write_all_spec_files(env, components) do
      linked_count = sync_and_link_components(scope, created_components)

      Logger.debug(
        "[Proposal] sync_and_link_components complete, linked_count: #{linked_count}"
      )

      warnings =
        collect_warnings(proposal) ++ removed_component_warnings(proposal, pre_existing_db_names)

      result =
        {:ok,
         %{
           created_contexts: Enum.count(proposal.contexts),
           created_components: length(created_components),
           linked_stories: linked_count,
           warnings: warnings
         }}

      Logger.info("[Proposal] Execution complete: #{inspect(result)}")
      result
    end
  end

  defp list_db_component_names(scope) do
    scope
    |> Components.list_components()
    |> Enum.map(& &1.module_name)
  end

  defp removed_component_warnings(proposal, pre_existing_db_names) do
    proposal_names = MapSet.new(collect_all_component_names(proposal))

    pre_existing_db_names
    |> Enum.reject(fn name -> MapSet.member?(proposal_names, name) end)
    |> Enum.map(fn name ->
      "Component removed from proposal but preserved in DB: #{name}. Delete the component manually if intended."
    end)
  end

  defp write_all_spec_files(env, components) do
    components
    |> Enum.reduce_while({:ok, []}, &write_one_spec(env, &1, &2))
    |> finalize_spec_writes()
  end

  defp write_one_spec(env, comp_attrs, {:ok, created}) do
    case write_spec_file(env, comp_attrs) do
      :ok -> {:cont, {:ok, [comp_attrs | created]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_spec_writes({:ok, created}), do: {:ok, Enum.reverse(created)}
  defp finalize_spec_writes(err), do: err

  defp sync_and_link_components(scope, components) do
    # Sync all components to database and collect surface components with their story mappings
    Logger.debug("[Proposal] sync_and_link_components: #{length(components)} components")

    components
    |> Enum.reduce(0, fn comp_attrs, linked_count ->
      Logger.debug(
        "[Proposal] Processing component: #{comp_attrs.module_name}, type: #{comp_attrs.type}"
      )

      case sync_component_to_db(scope, comp_attrs) do
        %{id: component_id} = component ->
          Logger.debug(
            "[Proposal] Component synced: #{component.module_name} -> id=#{component_id}"
          )

          maybe_link_stories(scope, comp_attrs, component_id, linked_count)

        {:error, reason} ->
          Logger.error(
            "[Proposal] Failed to sync component #{comp_attrs.module_name}: #{inspect(reason)}"
          )

          linked_count

        other ->
          Logger.error(
            "[Proposal] Unexpected return from sync_component_to_db: #{inspect(other)}"
          )

          linked_count
      end
    end)
  end

  # Link stories to any component that declares story_ids. Surface components
  # are preferred (Rule 2) but non-surface links are accepted with a warning
  # collected separately via collect_warnings/1.
  defp maybe_link_stories(scope, comp_attrs, component_id, linked_count) do
    story_ids = Map.get(comp_attrs, :story_ids, [])

    if story_ids == [] do
      linked_count
    else
      Logger.info(
        "[Proposal] Linking #{length(story_ids)} stories to #{comp_attrs.module_name}: #{inspect(story_ids)}"
      )

      link_stories_to_component(scope, story_ids, component_id)
      linked_count + length(story_ids)
    end
  end

  defp link_stories_to_component(scope, story_ids, component_id) do
    Enum.each(story_ids, fn story_id ->
      case Stories.get_story(scope, story_id) do
        nil ->
          Logger.warning("[Proposal] Story #{story_id} not found, skipping link")

        story ->
          set_story_component(scope, story, component_id)
      end
    end)
  end

  defp set_story_component(scope, story, component_id) do
    case Stories.set_story_component(scope, story, component_id) do
      {:ok, _story} ->
        Logger.debug("[Proposal] Linked story #{story.id} to component #{component_id}")

      {:error, reason} ->
        Logger.warning("[Proposal] Failed to link story #{story.id}: #{inspect(reason)}")
    end
  end

  defp child_story_links(child) do
    Enum.map(Map.get(child, :story_ids, []), fn story_id -> {story_id, child.name} end)
  end

  defp sync_component_to_db(scope, attrs) do
    component_attrs = %{
      module_name: attrs.module_name,
      type: attrs.type,
      description: attrs.description,
      name: attrs.module_name |> String.split(".") |> List.last()
    }

    Components.upsert_component(scope, component_attrs)
  end

  defp write_spec_file(env, attrs) do
    spec_path = build_spec_path(attrs.module_name)

    # Only write if file doesn't exist - preserve existing specs
    if Environments.file_exists?(env, spec_path) do
      Logger.debug("[Proposal] Spec file already exists, skipping: #{spec_path}")
      :ok
    else
      spec_content = generate_spec_template(attrs)
      Environments.write_file(env, spec_path, spec_content)
    end
  end

  defp count_linked_stories(proposal) do
    (proposal.contexts ++ proposal.surface_components)
    |> Enum.flat_map(fn item ->
      own_ids = Map.get(item, :story_ids, [])
      child_ids = item |> Map.get(:children, []) |> Enum.flat_map(&Map.get(&1, :story_ids, []))
      own_ids ++ child_ids
    end)
    |> Enum.uniq()
    |> length()
  end

  defp build_spec_path(module_name) do
    path_parts =
      module_name
      |> String.trim()
      |> String.split(".")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Macro.underscore/1)

    Path.join([CodeMySpec.Paths.spec_dir() | path_parts]) <> ".spec.md"
  end

  defp generate_spec_template(attrs) do
    deps = attrs[:dependencies] || []

    base = """
    # #{attrs.module_name}

    #{attrs.description || "No description provided"}

    ## Type

    #{attrs.type}
    """

    if deps != [] do
      base <> """

      ## Dependencies

      #{format_spec_dependencies(deps)}
      """
    else
      base
    end
  end

  defp format_spec_dependencies([]), do: "- None"

  defp format_spec_dependencies(deps) do
    Enum.map_join(deps, "\n", &"- #{&1}")
  end
end
