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

  alias CodeMySpec.Components
  alias CodeMySpec.Environments

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
      surface_components: normalize_components(attrs[:surface_components] || attrs["surface_components"] || []),
      dependencies: normalize_dependencies(attrs[:dependencies] || attrs["dependencies"] || []),
      unmapped_story_ids: attrs[:unmapped_story_ids] || attrs["unmapped_story_ids"] || []
    }
  end

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
      |> check_story_coverage(proposal, all_story_ids)
      |> check_dependency_cycles(proposal)
      |> check_duplicate_names(proposal)
      |> check_empty_contexts(proposal)

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
  Converts the proposal to a Mermaid diagram string.
  """
  @spec to_mermaid(t()) :: String.t()
  def to_mermaid(%__MODULE__{} = proposal) do
    context_nodes =
      proposal.contexts
      |> Enum.map(fn ctx ->
        id = sanitize_mermaid_id(ctx.name)
        label = ctx.name
        "    #{id}[#{label}]"
      end)
      |> Enum.join("\n")

    surface_nodes =
      proposal.surface_components
      |> Enum.map(fn comp ->
        id = sanitize_mermaid_id(comp.name)
        label = "#{comp.name}<br/>#{comp.type}"
        "    #{id}([#{label}])"
      end)
      |> Enum.join("\n")

    dependency_edges =
      proposal.dependencies
      |> Enum.map(fn dep ->
        from_id = sanitize_mermaid_id(dep.from)
        to_id = sanitize_mermaid_id(dep.to)
        "    #{from_id} --> #{to_id}"
      end)
      |> Enum.join("\n")

    """
    flowchart TD
        subgraph Contexts
    #{context_nodes}
        end

        subgraph Surface
    #{surface_nodes}
        end

    #{dependency_edges}
    """
  end

  @doc """
  Returns all component definitions from the proposal for creation.
  """
  @spec to_components(t()) :: [map()]
  def to_components(%__MODULE__{} = proposal) do
    context_components =
      proposal.contexts
      |> Enum.flat_map(fn ctx ->
        parent = %{
          module_name: ctx.name,
          type: "context",
          description: ctx.description,
          story_ids: ctx.story_ids
        }

        children =
          ctx.children
          |> Enum.map(fn child ->
            %{
              module_name: "#{ctx.name}.#{child.name}",
              type: child.type,
              description: child.description,
              parent_module: ctx.name,
              story_ids: child.story_ids
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
          story_ids: comp.story_ids
        }
      end)

    context_components ++ surface
  end

  # Private functions

  defp normalize_contexts(contexts) do
    Enum.map(contexts, fn ctx ->
      %{
        name: ctx[:name] || ctx["name"] || ctx[:module_name] || ctx["module_name"],
        description: ctx[:description] || ctx["description"] || "",
        children: normalize_components(ctx[:children] || ctx["children"] || []),
        story_ids: ctx[:story_ids] || ctx["story_ids"] || []
      }
    end)
  end

  defp normalize_components(components) do
    Enum.map(components, fn comp ->
      %{
        name: comp[:name] || comp["name"] || comp[:module_name] || comp["module_name"],
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

  defp check_story_coverage(errors, _proposal, all_story_ids) when all_story_ids == [] do
    errors
  end

  defp check_story_coverage(errors, proposal, all_story_ids) do
    mapped_ids =
      (proposal.contexts ++ proposal.surface_components)
      |> Enum.flat_map(fn item ->
        own_ids = Map.get(item, :story_ids, [])
        child_ids = item |> Map.get(:children, []) |> Enum.flat_map(&Map.get(&1, :story_ids, []))
        own_ids ++ child_ids
      end)
      |> MapSet.new()

    all_ids = MapSet.new(all_story_ids)
    unmapped = MapSet.difference(all_ids, mapped_ids) |> MapSet.to_list()

    if unmapped == [] do
      errors
    else
      [
        %{
          type: :unmapped_stories,
          message: "Some stories are not mapped to any component",
          details: %{story_ids: unmapped}
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

  defp check_empty_contexts(errors, proposal) do
    empty =
      proposal.contexts
      |> Enum.filter(fn ctx -> ctx.children == [] and ctx.story_ids == [] end)
      |> Enum.map(& &1.name)

    if empty == [] do
      errors
    else
      [
        %{
          type: :empty_contexts,
          message: "Contexts without children or stories found",
          details: %{names: empty}
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
          dfs_find_cycle(graph, start, neighbor, path ++ [neighbor], MapSet.put(visited, neighbor))
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

  defp do_execute(proposal, scope, opts \\ []) do
    components = to_components(proposal)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    with {:ok, env} <- Environments.create(:cli, working_dir: working_dir) do
      results =
        Enum.reduce_while(components, {:ok, []}, fn comp_attrs, {:ok, created} ->
          case create_component(scope, env, comp_attrs) do
            {:ok, component} -> {:cont, {:ok, [component | created]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      Environments.destroy(env)

      case results do
        {:ok, created} ->
          {:ok,
           %{
             created_contexts: Enum.count(proposal.contexts),
             created_components: length(created),
             linked_stories: count_linked_stories(proposal)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_component(scope, env, attrs) do
    spec_path = build_spec_path(attrs.module_name)
    spec_content = generate_spec_template(attrs)

    with :ok <- Environments.write_file(env, spec_path, spec_content) do
      component_attrs =
        %{
          module_name: attrs.module_name,
          type: attrs.type,
          description: attrs.description,
          name: derive_name(attrs.module_name)
        }
        |> maybe_put_parent_id(scope, attrs[:parent_module])

      case Components.upsert_component(scope, component_attrs) do
        %{id: _} = component ->
          maybe_link_stories(scope, component, attrs[:story_ids])
          {:ok, component}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp maybe_link_stories(_scope, _component, nil), do: :ok
  defp maybe_link_stories(_scope, _component, []), do: :ok

  defp maybe_link_stories(scope, component, story_ids) do
    alias CodeMySpec.Stories

    Enum.each(story_ids, fn story_id ->
      case Stories.get_story(scope, story_id) do
        nil -> :ok
        story -> Stories.set_story_component(scope, story, component.id)
      end
    end)
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
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["docs/spec" | path_parts]) <> ".spec.md"
  end

  defp derive_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp generate_spec_template(attrs) do
    """
    # #{attrs.module_name}

    #{attrs.description || "No description provided"}

    ## Type

    #{attrs.type}

    ## Dependencies

    - None

    ## Functions

    """
  end

  defp sanitize_mermaid_id(name) do
    name
    |> String.replace(".", "_")
    |> String.replace(~r/[^a-zA-Z0-9_]/, "")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_parent_id(map, _scope, nil), do: map

  defp maybe_put_parent_id(map, scope, parent_module) do
    case Components.get_component_by_module_name(scope, parent_module) do
      nil -> map
      parent -> Map.put(map, :parent_component_id, parent.id)
    end
  end
end
