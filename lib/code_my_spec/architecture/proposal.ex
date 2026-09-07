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

  alias CodeMySpec.Architecture.SpecStub
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
          type: String.t(),
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
      |> check_invalid_types(proposal)
      |> check_story_surface_mapping(proposal, all_story_ids)
      |> check_dependency_cycles(proposal)
      |> check_duplicate_names(proposal)
      |> check_dependency_resolution(proposal, known_db_components)
      |> check_orphan_components(proposal)

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
          type: Map.get(ctx, :type, "context"),
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
        type: get_attr(ctx, :type, "context"),
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

  # Every non-infrastructure context must be either (a) directly story-linked
  # (own or via a child), or (b) reachable as a transitive dependency from a
  # story-linked component. Otherwise it's an orphan — declared but with no
  # work to drive, which is the architectural smell the rule catches.
  #
  # Infrastructure-typed contexts (framework-generated OTP/web modules) are
  # exempt. They're declared so they're tracked, not because they need
  # specs/tests/implementation work.
  defp check_orphan_components(errors, proposal) do
    story_linked_names = collect_story_linked_names(proposal)
    deps_graph = build_dependency_graph(proposal)
    reachable = transitive_reachable(story_linked_names, deps_graph)

    orphans =
      proposal.contexts
      |> Enum.reject(fn ctx ->
        ctx.type == "infrastructure" or
          context_story_linked?(ctx) or
          MapSet.member?(reachable, ctx.name)
      end)
      |> Enum.map(& &1.name)

    if orphans == [] do
      errors
    else
      [
        %{
          type: :orphan_components,
          message:
            "Components must be linked to a story, transitively depended on by a story-linked component, or marked as infrastructure",
          details: %{orphan_components: orphans}
        }
        | errors
      ]
    end
  end

  defp context_story_linked?(ctx) do
    Map.get(ctx, :story_ids, []) != [] or
      Enum.any?(Map.get(ctx, :children, []), fn child ->
        Map.get(child, :story_ids, []) != []
      end)
  end

  defp collect_story_linked_names(proposal) do
    surface_names =
      proposal.surface_components
      |> Enum.filter(fn comp ->
        Map.get(comp, :story_ids, []) != [] or
          Enum.any?(Map.get(comp, :children, []), fn child ->
            Map.get(child, :story_ids, []) != []
          end)
      end)
      |> Enum.map(& &1.name)

    context_names =
      proposal.contexts
      |> Enum.filter(&context_story_linked?/1)
      |> Enum.map(& &1.name)

    MapSet.new(surface_names ++ context_names)
  end

  defp transitive_reachable(seeds, deps_graph) do
    Enum.reduce(seeds, MapSet.new(), fn seed, acc ->
      walk_deps(seed, deps_graph, acc)
    end)
  end

  defp walk_deps(node, deps_graph, visited) do
    if MapSet.member?(visited, node) do
      visited
    else
      visited = MapSet.put(visited, node)

      deps_graph
      |> Map.get(node, [])
      |> Enum.reduce(visited, fn neighbor, acc -> walk_deps(neighbor, deps_graph, acc) end)
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

  @valid_types ~w(context schema module liveview liveview_component live_context controller component channel plug infrastructure)

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
      nil -> resolve_env_from_working_dir(opts)
      env -> {:ok, env, false}
    end
  end

  # Executing a proposal writes spec files. Defaulting the directory
  # to this process's meant writing them into the server's own
  # checkout, so the caller must say where.
  defp resolve_env_from_working_dir(opts) do
    case Keyword.get(opts, :working_dir) do
      nil ->
        {:error, :no_working_copy}

      working_dir ->
        case Environments.create(:cli, working_dir: working_dir) do
          {:ok, env} -> {:ok, env, true}
          {:error, _} = err -> err
        end
    end
  end

  defp do_execute_with_env(proposal, scope, components, env) do
    pre_existing_db_names = list_db_component_names(scope)

    with {:ok, created_components} <- write_all_spec_files(env, components) do
      linked_count = sync_and_link_components(scope, created_components)

      Logger.debug("[Proposal] sync_and_link_components complete, linked_count: #{linked_count}")

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

  # Order is preserved (ordered: true default) so surface components, which
  # come last in `to_components/1`, are still processed after contexts in
  # `sync_and_link_components/2`. That ordering is what makes surface links
  # win when a story is claimed by both a context and a surface component.
  defp write_all_spec_files(env, components) do
    components
    |> Task.async_stream(fn comp -> {comp, write_one_spec(env, comp)} end,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {comp, :ok}}, {:ok, acc} ->
        {:cont, {:ok, [comp | acc]}}

      {:ok, {_comp, {:error, _} = err}}, _ ->
        {:halt, err}

      {:exit, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # Infrastructure components are framework-generated modules (OTP application,
  # web endpoint, mailer, etc.). They get a Component row in the DB but no spec
  # stub — their requirement graph template is empty, so no agent work is
  # driven for them.
  defp write_one_spec(_env, %{type: "infrastructure"}), do: :ok
  defp write_one_spec(env, comp_attrs), do: write_spec_file(env, comp_attrs)

  # Two stages:
  #   1. Upsert every component locally and build the (story_id, component_id)
  #      link list in input order. Surface components come last in the input,
  #      so duplicate story claims (context + surface) end up with the surface
  #      link last — that's what gives surface its "wins on overwrite" property
  #      once the bulk call applies them in order.
  #   2. One `Stories.bulk_set_story_component/2` call. On the CLI this is a
  #      single HTTP POST + a single local-cache write-through transaction,
  #      replacing 2N round-trips.
  defp sync_and_link_components(scope, components) do
    Logger.debug("[Proposal] sync_and_link_components: #{length(components)} components")

    raw_links =
      Enum.flat_map(components, fn comp_attrs ->
        case sync_component_to_db(scope, comp_attrs) do
          %{id: component_id} ->
            comp_attrs
            |> Map.get(:story_ids, [])
            |> Enum.map(&%{story_id: &1, component_id: component_id})

          {:error, reason} ->
            Logger.error(
              "[Proposal] Failed to sync component #{comp_attrs.module_name}: #{inspect(reason)}"
            )

            []

          other ->
            Logger.error(
              "[Proposal] Unexpected return from sync_component_to_db: #{inspect(other)}"
            )

            []
        end
      end)

    # Dedupe by story_id keeping the LAST occurrence. `components` is ordered
    # `context_components ++ surface`, so the last claim of a given story_id
    # belongs to the surface component. Deduping here makes "surface wins"
    # deterministic — independent of `apply_link/4`'s order semantics or any
    # downstream reordering in the bulk path.
    links = dedupe_links_last_wins(raw_links)

    apply_story_links(scope, links)
  end

  defp dedupe_links_last_wins(links) do
    links
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.story_id)
    |> Enum.reverse()
  end

  defp apply_story_links(_scope, []), do: 0

  defp apply_story_links(scope, links) do
    Logger.info("[Proposal] Bulk-linking #{length(links)} story→component pairs")

    case Stories.bulk_set_story_component(scope, links) do
      {:ok, _stories} ->
        length(links)

      {:error, reason} ->
        Logger.warning("[Proposal] Bulk story link failed: #{inspect(reason)}")
        0
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
    case SpecStub.write(env, attrs) do
      :ok -> :ok
      {:error, _} = err -> err
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
end
