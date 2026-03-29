defmodule CodeMySpec.Files.ComponentSync do
  @moduledoc """
  Syncs components from File records.

  After FileSync populates the files table, this module:
  1. Reads spec/impl Files to derive components
  2. Parses changed spec files for metadata (type, description, dependencies)
  3. Upserts components
  4. Derives parent relationships from module name hierarchy
  5. Syncs declared dependencies
  6. Backfills component_id on File records

  This replaces the old `Components.Sync.sync_changed` which globbed the
  filesystem directly. The File model is now the source of truth.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files.File
  alias CodeMySpec.Paths
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type sync_result :: %{
          all_components: [Component.t()],
          changed_component_ids: [Ecto.UUID.t()]
        }

  @doc """
  Sync components from File records.

  Reads spec and impl files from the DB, parses changed ones for metadata,
  upserts components, resolves parent relationships and dependencies,
  then backfills component_id on File records.

  ## Options
  - `:base_dir` — project root for reading file content (required for parsing)
  """
  @spec sync_from_files(Scope.t(), keyword()) :: {:ok, sync_result()}
  def sync_from_files(%Scope{} = scope, opts \\ []) do
    base_dir = Keyword.fetch!(opts, :base_dir)
    start = System.monotonic_time(:millisecond)

    # Get all spec and impl files from DB
    project_id = scope.active_project_id

    spec_files =
      File
      |> where([f], f.project_id == ^project_id and f.role == :spec)
      |> Repo.all()

    impl_files =
      File
      |> where([f], f.project_id == ^project_id and f.role == :implementation)
      |> Repo.all()

    # Parse spec files — only read content for files needing validation (valid is nil)
    spec_data = Enum.map(spec_files, &parse_spec_file(&1, base_dir))
    impl_data = Enum.map(impl_files, &parse_impl_file(&1, base_dir))

    # Merge by module name (spec + impl → one component)
    merged = merge_by_module_name(spec_data, impl_data)

    # Filter ignored components
    ignored = load_ignored(scope)
    merged = Enum.reject(merged, &(&1.module_name in ignored))

    # Upsert components
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing_components = Components.list_components(scope)
    existing_map = Map.new(existing_components, &{&1.module_name, &1})

    synced_components = Enum.map(merged, &upsert_component(scope, &1, now))
    component_map = Map.new(synced_components, &{&1.module_name, &1})

    # Detect which components changed (new or updated)
    changed_component_ids =
      synced_components
      |> Enum.filter(fn c ->
        case Map.get(existing_map, c.module_name) do
          nil -> true
          existing -> existing.updated_at != c.updated_at
        end
      end)
      |> Enum.map(& &1.id)

    # Derive parent relationships
    update_parent_relationships(scope, synced_components, component_map)

    # Sync dependencies from spec declarations
    sync_dependencies(scope, merged, component_map)

    # Clean up removed components
    all_module_names = MapSet.new(merged, & &1.module_name)
    cleanup_removed(scope, existing_components, all_module_names)

    # Backfill component_id on File records
    backfill_file_owners(scope, component_map)

    ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[Files.ComponentSync] #{length(synced_components)} components synced in #{ms}ms " <>
        "(#{length(changed_component_ids)} changed)"
    )

    {:ok,
     %{
       all_components: synced_components,
       changed_component_ids: changed_component_ids
     }}
  end

  # -- Spec parsing --

  # sobelow_skip ["Traversal.FileModule"]
  defp parse_spec_file(%File{path: path} = _file, base_dir) do
    module_name = module_name_from_path(path, :spec)
    abs_path = Path.join(base_dir, path)

    {type, description, dependencies} =
      case Elixir.File.read(abs_path) do
        {:ok, content} ->
          {extract_type_section(content), extract_intro_text(content), extract_dependencies(content)}

        {:error, _} ->
          {nil, nil, []}
      end

    %{
      module_name: module_name,
      type: type,
      description: description,
      dependencies: dependencies
    }
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp parse_impl_file(%File{path: path} = _file, base_dir) do
    abs_path = Path.join(base_dir, path)
    fallback = module_name_from_path(path, :implementation)

    module_name =
      case Elixir.File.read(abs_path) do
        {:ok, content} ->
          case Regex.run(~r/defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
            [_, name] -> name
            _ -> fallback
          end

        {:error, _} ->
          fallback
      end

    %{module_name: module_name, type: nil, description: nil, dependencies: []}
  end

  # -- Module name derivation --

  defp module_name_from_path(path, :spec) do
    path
    |> String.replace_prefix(Paths.spec_dir() <> "/", "")
    |> String.replace_suffix(".spec.md", "")
    |> path_to_module()
  end

  defp module_name_from_path(path, :implementation) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> path_to_module()
  end

  defp path_to_module(path) do
    path
    |> String.split("/")
    |> Enum.map_join(".", fn segment ->
      segment |> String.split("_") |> Enum.map_join(&String.capitalize/1)
    end)
  end

  # -- Merge --

  defp merge_by_module_name(spec_data, impl_data) do
    spec_map = Map.new(spec_data, &{&1.module_name, &1})
    impl_map = Map.new(impl_data, &{&1.module_name, &1})

    all_names =
      MapSet.union(MapSet.new(Map.keys(spec_map)), MapSet.new(Map.keys(impl_map)))

    Enum.map(all_names, fn name ->
      spec = Map.get(spec_map, name, %{module_name: name, type: nil, description: nil, dependencies: []})
      impl = Map.get(impl_map, name, %{module_name: name, type: nil, description: nil, dependencies: []})

      %{
        module_name: name,
        type: spec.type || impl.type,
        description: spec.description || impl.description,
        dependencies: spec.dependencies || []
      }
    end)
  end

  # -- Upsert --

  defp upsert_component(%Scope{} = scope, data, synced_at) do
    attrs =
      %{
        module_name: data.module_name,
        name: data.module_name |> String.split(".") |> List.last(),
        description: data.description,
        synced_at: synced_at
      }
      |> maybe_put(:type, data.type)

    Components.upsert_component(scope, attrs)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # -- Parent relationships --

  defp update_parent_relationships(scope, components, component_map) do
    Enum.each(components, fn component ->
      case find_nearest_ancestor(component.module_name, component_map) do
        nil ->
          if component.parent_component_id do
            Components.update_component(scope, component, %{parent_component_id: nil})
          end

        parent when parent.id != component.id ->
          if parent.id != component.parent_component_id do
            Components.update_component(scope, component, %{parent_component_id: parent.id})
          end

        _ ->
          :ok
      end
    end)
  end

  defp find_nearest_ancestor(module_name, component_map) do
    case parent_module_name(module_name) do
      nil -> nil
      parent_name ->
        case Map.get(component_map, parent_name) do
          nil -> find_nearest_ancestor(parent_name, component_map)
          parent -> parent
        end
    end
  end

  defp parent_module_name(module_name) do
    parts = String.split(module_name, ".")
    if length(parts) > 1, do: parts |> Enum.drop(-1) |> Enum.join("."), else: nil
  end

  # -- Dependencies --

  defp sync_dependencies(scope, merged_data, component_map) do
    Enum.each(merged_data, fn data ->
      case Map.get(component_map, data.module_name) do
        nil -> :ok
        source -> sync_component_dependencies(scope, source, data, component_map)
      end
    end)
  end

  defp sync_component_dependencies(scope, source, data, component_map) do
    current_deps = Components.list_component_dependencies(scope, source.id)
    current_target_ids = MapSet.new(current_deps, & &1.target_component_id)

    declared_deps =
      (data.dependencies || [])
      |> Enum.map(&Map.get(component_map, &1))
      |> Enum.reject(&(is_nil(&1) || &1.id == source.id))

    declared_target_ids = MapSet.new(declared_deps, & &1.id)

    # Add new
    MapSet.difference(declared_target_ids, current_target_ids)
    |> Enum.each(fn target_id ->
      Components.create_dependency(scope, %{
        source_component_id: source.id,
        target_component_id: target_id
      })
    end)

    # Remove old
    removed = MapSet.difference(current_target_ids, declared_target_ids)

    Enum.each(current_deps, fn dep ->
      if dep.target_component_id in removed do
        Components.delete_dependency(scope, dep)
      end
    end)
  end

  # -- Cleanup --

  defp cleanup_removed(%Scope{} = scope, existing, current_names) do
    existing
    |> Enum.reject(&(&1.module_name in current_names))
    |> Enum.each(&Components.delete_component(scope, &1))
  end

  # -- Backfill file ownership --

  defp backfill_file_owners(%Scope{active_project_id: project_id}, component_map) do
    # For each component, update its spec/impl/test files
    Enum.each(component_map, fn {module_name, component} ->
      module_path = module_name_to_path(module_name)

      patterns = [
        Paths.spec_dir() <> "/#{module_path}.spec.md",
        "lib/#{module_path}.ex",
        "test/#{module_path}_test.exs"
      ]

      File
      |> where([f], f.project_id == ^project_id and f.path in ^patterns and is_nil(f.component_id))
      |> Repo.update_all(set: [component_id: component.id])
    end)
  end

  defp module_name_to_path(module_name) do
    module_name
    |> Macro.underscore()
    |> String.replace(".", "/")
  end

  # -- Ignored components --

  defp load_ignored(%Scope{cwd: nil}), do: MapSet.new()

  defp load_ignored(%Scope{cwd: cwd}) do
    case Scope.read_local_config(cwd) do
      {:ok, %{"ignored_components" => list}} when is_list(list) -> MapSet.new(list)
      _ -> MapSet.new()
    end
  end

  # -- Spec content extraction (reused from Components.Sync) --

  defp extract_type_section(content) do
    section_type =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    section_type ||
      case Regex.run(~r/^\*\*Type\*\*:\s*(.+)$/m, content) do
        [_, type] -> String.trim(type) |> String.downcase()
        nil -> nil
      end
  end

  defp extract_intro_text(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^# [A-Z]/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_dependencies(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^## Dependencies/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(fn line ->
      line |> String.replace_prefix("- ", "") |> String.trim()
    end)
    |> Enum.reject(&(&1 == "" || &1 == "None"))
  end
end
