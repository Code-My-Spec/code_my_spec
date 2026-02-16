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
      app_name: attrs[:app_name] || attrs["app_name"] || "App",
      contexts: normalize_contexts(attrs[:contexts] || attrs["contexts"] || []),
      surface_components:
        normalize_components(attrs[:surface_components] || attrs["surface_components"] || []),
      dependencies: normalize_dependencies(attrs[:dependencies] || attrs["dependencies"] || []),
      unmapped_story_ids: attrs[:unmapped_story_ids] || attrs["unmapped_story_ids"] || []
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

    errors =
      []
      |> check_naming_conventions(proposal)
      |> check_naming_hierarchy(proposal)
      |> check_consecutive_capitals(proposal)
      |> check_invalid_types(proposal)
      |> check_story_surface_mapping(proposal, all_story_ids)
      |> check_dependency_cycles(proposal)
      |> check_duplicate_names(proposal)

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
      |> Enum.map(fn comp ->
        %{
          module_name: comp.name,
          type: comp.type,
          description: comp.description,
          story_ids: comp.story_ids,
          dependencies: Map.get(deps_map, comp.name, [])
        }
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

  defp normalize_contexts(contexts) do
    Enum.map(contexts, fn ctx ->
      name = ctx[:name] || ctx["name"] || ctx[:module_name] || ctx["module_name"]

      %{
        name: if(is_binary(name), do: String.trim(name), else: name),
        description: ctx[:description] || ctx["description"] || "",
        children: normalize_components(ctx[:children] || ctx["children"] || []),
        story_ids: ctx[:story_ids] || ctx["story_ids"] || []
      }
    end)
  end

  defp normalize_components(components) do
    Enum.map(components, fn comp ->
      name = comp[:name] || comp["name"] || comp[:module_name] || comp["module_name"]

      %{
        name: if(is_binary(name), do: String.trim(name), else: name),
        type: comp[:type] || comp["type"],
        description: comp[:description] || comp["description"] || "",
        story_ids: comp[:story_ids] || comp["story_ids"] || []
      }
    end)
  end

  defp normalize_dependencies(deps) do
    Enum.map(deps, fn dep ->
      %{
        from: dep[:from] || dep["from"],
        to: dep[:to] || dep["to"]
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

    all_invalid = invalid_contexts ++ invalid_surfaces ++ invalid_children

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

      [
        %{
          type: :invalid_naming_hierarchy,
          message: Enum.join(messages, ". "),
          details: %{
            invalid_contexts: invalid_contexts,
            invalid_surfaces: invalid_surfaces,
            invalid_children: invalid_children
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
    # Stories must be mapped to surface components (LiveViews, Controllers)
    # This is required for BDD spec generation - we test user behavior at the surface level
    surface_mapped =
      proposal.surface_components
      |> Enum.flat_map(fn comp -> Map.get(comp, :story_ids, []) end)
      |> MapSet.new()

    all_ids = MapSet.new(all_story_ids)
    missing_surface = MapSet.difference(all_ids, surface_mapped) |> MapSet.to_list()

    if missing_surface == [] do
      errors
    else
      [
        %{
          type: :stories_missing_surface,
          message: "Each story must be mapped to a surface component (LiveView/Controller)",
          details: %{story_ids: missing_surface}
        }
        | errors
      ]
    end
  end

  defp check_dependency_cycles(errors, proposal) do
    graph = build_dependency_graph(proposal)
    cycles = find_cycles(graph)

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

  defp check_consecutive_capitals(errors, proposal) do
    # Consecutive capitals like "LLM" become "l_l_m" via Macro.underscore/1
    # If you want "llm", name it "Llm" instead
    all_names = collect_all_component_names(proposal)

    with_consecutive =
      all_names
      |> Enum.filter(&has_consecutive_capitals?/1)

    if with_consecutive == [] do
      errors
    else
      [
        %{
          type: :consecutive_capitals,
          message:
            "Module names with consecutive capitals will underscore each letter (e.g., LLM -> l_l_m.ex). Use Llm for llm.ex",
          details: %{names: with_consecutive}
        }
        | errors
      ]
    end
  end

  defp collect_all_component_names(proposal) do
    context_names = Enum.map(proposal.contexts, & &1.name)

    child_names =
      proposal.contexts
      |> Enum.flat_map(fn ctx -> Enum.map(ctx.children, & &1.name) end)

    surface_names = Enum.map(proposal.surface_components, & &1.name)

    context_names ++ child_names ++ surface_names
  end

  defp has_consecutive_capitals?(name) do
    # Check each segment of the module name for consecutive capitals
    name
    |> String.split(".")
    |> Enum.any?(fn segment ->
      # Match 2+ consecutive uppercase letters
      Regex.match?(~r/[A-Z]{2,}/, segment)
    end)
  end

  @valid_types ~w(context schema module liveview controller component channel plug)

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
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    with {:ok, env} <- Environments.create(:cli, working_dir: working_dir) do
      # Write spec files
      file_results =
        Enum.reduce_while(components, {:ok, []}, fn comp_attrs, {:ok, created} ->
          case write_spec_file(env, comp_attrs) do
            :ok -> {:cont, {:ok, [comp_attrs | created]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      Environments.destroy(env)

      case file_results do
        {:ok, created_components} ->
          # Sync to database and link stories to surface components
          Logger.debug(
            "[Proposal] Starting sync_and_link_components with #{length(created_components)} components"
          )

          linked_count = sync_and_link_components(scope, created_components)

          Logger.debug(
            "[Proposal] sync_and_link_components complete, linked_count: #{linked_count}"
          )

          result =
            {:ok,
             %{
               created_contexts: Enum.count(proposal.contexts),
               created_components: length(created_components),
               linked_stories: linked_count
             }}

          Logger.info("[Proposal] Execution complete: #{inspect(result)}")
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

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

          # Link stories to surface components (liveview, controller)
          # Handle "(existing)" suffix in type (e.g., "liveview (existing)")
          base_type = comp_attrs.type |> String.split(" ") |> hd()

          if base_type in ["liveview", "controller"] do
            story_ids = Map.get(comp_attrs, :story_ids, [])

            Logger.info(
              "[Proposal] Linking #{length(story_ids)} stories to #{comp_attrs.module_name}: #{inspect(story_ids)}"
            )

            link_stories_to_component(scope, story_ids, component_id)
            linked_count + length(story_ids)
          else
            linked_count
          end

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

  defp link_stories_to_component(scope, story_ids, component_id) do
    Enum.each(story_ids, fn story_id ->
      case Stories.get_story(scope, story_id) do
        nil ->
          Logger.warning(
            "[Proposal] Story #{story_id} not found for scope project #{inspect(scope.active_project_id)}"
          )

        story ->
          case Stories.set_story_component(scope, story, component_id) do
            {:ok, _updated} ->
              Logger.debug("[Proposal] Linked story #{story_id} to component #{component_id}")

            {:error, reason} ->
              Logger.error("[Proposal] Failed to link story #{story_id}: #{inspect(reason)}")
          end
      end
    end)
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

    Path.join(["docs/spec" | path_parts]) <> ".spec.md"
  end

  defp generate_spec_template(attrs) do
    """
    # #{attrs.module_name}

    #{attrs.description || "No description provided"}

    ## Type

    #{attrs.type}

    ## Dependencies

    #{format_spec_dependencies(attrs[:dependencies] || [])}

    ## Functions

    """
  end

  defp format_spec_dependencies([]), do: "- None"

  defp format_spec_dependencies(deps) do
    deps
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end
end
