defmodule CodeMySpec.Components.Sync do
  @moduledoc """
  Synchronizes components from filesystem to database. Parent-child relationships
  are derived from module name hierarchy.

  ## Optimized sync phases

  This module provides three separate phases for efficient incremental syncing:

  1. `sync_changed/2` - Identifies and syncs only changed components
  2. `update_parent_relationships/4` - Updates parent relationships for affected components only
  3. `sync_all/2` - Backward-compatible full sync (delegates to new functions)

  Each phase pre-filters before expensive operations, reducing file I/O and database writes.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Sync.FileInfo
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.Paths, as: UtilPaths

  @type parse_error :: {path :: String.t(), reason :: term()}

  @doc """
  Synchronizes only changed components from spec files and implementation files.

  Returns `{:ok, all_components, changed_component_ids}` where:
  - `all_components` is the complete list of components (changed + unchanged)
  - `changed_component_ids` is the list of IDs for components that were modified

  Module names come from:
  1. Implementation's declared module name (highest priority)
  2. Spec's H1 title
  3. Path-derived name (lowest priority)

  Component type comes from the spec's `## Type` section. If absent, nil.

  ## Options

  - `:base_dir` - Base directory to scan (defaults to current working directory)
  - `:force` - When true, ignores mtime and syncs all files (defaults to false)
  - `:ignored_components` - List of fully qualified module names to exclude (e.g., `["MyApp.Repo"]`)

  ## Optimization

  Pre-filters files by mtime BEFORE parsing. Unchanged files are never read.
  """
  @spec sync_changed(Scope.t(), keyword()) ::
          {:ok, [Component.t()], [binary()]} | {:error, term()}
  def sync_changed(%Scope{} = scope, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, ".")
    force = Keyword.get(opts, :force, false)

    # Delete any existing components that are now ignored (immediate cleanup)
    ignored_list = Keyword.get(opts, :ignored_components, [])
    ignored = MapSet.new(ignored_list)
    Logger.info("[Sync] ignored_components option: #{inspect(ignored_list)} (#{MapSet.size(ignored)} entries)")
    cleanup_ignored(scope, ignored)

    # Load existing components and build files_changed_at lookup for mtime comparison
    existing_components = Components.list_components(scope)
    changed_at_map = Map.new(existing_components, fn c -> {c.module_name, c.files_changed_at} end)

    # Collect file infos with mtimes
    spec_file_infos = FileInfo.collect_files(base_dir, Paths.spec_glob())
    impl_file_infos = FileInfo.collect_files(base_dir, "lib/**/*.ex")

    # PRE-FILTER by mtime BEFORE parsing (key optimization)
    {changed_spec_files, unchanged_spec_files} =
      filter_files_by_mtime(spec_file_infos, changed_at_map, force, :spec, base_dir)

    {changed_impl_files, unchanged_impl_files} =
      filter_files_by_mtime(impl_file_infos, changed_at_map, force, :impl, base_dir)

    # Parse changed files
    {changed_spec_data, spec_errors} =
      parse_files(changed_spec_files, &parse_spec_file(&1, base_dir))

    {changed_impl_data, impl_errors} =
      parse_files(changed_impl_files, &parse_impl_file(&1, base_dir))

    # When an impl file changed but its spec didn't (or vice versa), we need
    # the counterpart's data for a correct merge (especially for type info).
    # Find unchanged counterparts of changed files and parse them too.
    changed_spec_modules = MapSet.new(changed_spec_data, & &1.module_name)
    changed_impl_modules = MapSet.new(changed_impl_data, & &1.module_name)

    {counterpart_spec_files, unchanged_spec_files} =
      Enum.split_with(unchanged_spec_files, fn file_info ->
        module = derive_module_from_path(file_info.path, base_dir, :spec)
        module in changed_impl_modules and module not in changed_spec_modules
      end)

    {counterpart_impl_files, unchanged_impl_files} =
      Enum.split_with(unchanged_impl_files, fn file_info ->
        module = derive_module_from_path(file_info.path, base_dir, :impl)
        module in changed_spec_modules and module not in changed_impl_modules
      end)

    {counterpart_spec_data, counterpart_spec_errors} =
      parse_files(counterpart_spec_files, &parse_spec_file(&1, base_dir))

    {counterpart_impl_data, counterpart_impl_errors} =
      parse_files(counterpart_impl_files, &parse_impl_file(&1, base_dir))

    all_spec_data = changed_spec_data ++ counterpart_spec_data
    all_impl_data = changed_impl_data ++ counterpart_impl_data

    parse_errors = spec_errors ++ impl_errors ++ counterpart_spec_errors ++ counterpart_impl_errors

    Enum.each(parse_errors, fn {path, error} ->
      Logger.warning("Failed to parse #{path}: #{inspect(error)}")
    end)

    # For unchanged files, derive module names from paths (no file I/O)
    unchanged_spec_modules =
      extract_module_names_from_paths(unchanged_spec_files, base_dir, :spec)

    unchanged_impl_modules =
      extract_module_names_from_paths(unchanged_impl_files, base_dir, :impl)

    # Merge changed data by module name (now includes counterpart data for correct type merging)
    changed_merged = merge_by_module_name(all_spec_data, all_impl_data)

    unchanged_module_names =
      MapSet.union(
        MapSet.new(unchanged_spec_modules),
        MapSet.new(unchanged_impl_modules)
      )

    # Filter out ignored components (by fully qualified module name)
    ignored = MapSet.new(Keyword.get(opts, :ignored_components, []))
    changed_merged = reject_ignored(changed_merged, ignored)
    unchanged_module_names = MapSet.difference(unchanged_module_names, ignored)

    # Upsert ONLY changed components
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changed_module_names_list = Enum.map(changed_merged, & &1.module_name)
    Logger.info("[Sync] Changed modules (#{length(changed_module_names_list)}): #{Enum.join(changed_module_names_list, ", ")}")

    synced_components = Enum.map(changed_merged, &upsert_from_data(scope, &1, now))
    changed_component_ids = Enum.map(synced_components, & &1.id)

    # Get unchanged components from existing (already in DB, no upsert needed)
    unchanged_components =
      Enum.filter(existing_components, &(&1.module_name in unchanged_module_names))

    all_components = synced_components ++ unchanged_components

    # Cleanup removed components
    all_module_names =
      MapSet.new(changed_merged, & &1.module_name)
      |> MapSet.union(unchanged_module_names)

    cleanup_removed(scope, existing_components, all_module_names)

    # Sync dependencies for changed components
    sync_dependencies(scope, changed_merged, all_components)

    {:ok, all_components, changed_component_ids}
  rescue
    error ->
      Logger.error("Error during sync_changed: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Updates parent relationships for components that were affected by changes.

  Only updates components that:
  - Were just synced (in `changed_component_ids` list)
  - Have a parent that was just synced (parent created/deleted affects children)

  Returns `{:ok, expanded_changed_ids}` where expanded_changed_ids includes:
  - Original changed component IDs
  - Additional component IDs whose parent relationships changed

  ## Options

  - `:force` - When true, updates all parent relationships (defaults to false)
  """
  @spec update_parent_relationships(Scope.t(), [Component.t()], [binary()], keyword()) ::
          {:ok, [binary()]} | {:error, term()}
  def update_parent_relationships(
        %Scope{} = scope,
        all_components,
        changed_component_ids,
        opts \\ []
      ) do
    force = Keyword.get(opts, :force, false)

    if force do
      # Force mode: update all parent relationships
      derive_all_parent_relationships(scope, all_components)
      {:ok, Enum.map(all_components, & &1.id)}
    else
      # Incremental mode: only update affected components
      component_map = Map.new(all_components, &{&1.module_name, &1})
      changed_ids_set = MapSet.new(changed_component_ids)

      # Build map of id -> module_name for reverse lookup
      id_to_module = Map.new(all_components, &{&1.id, &1.module_name})

      changed_module_names =
        changed_component_ids
        |> Enum.map(&Map.get(id_to_module, &1))
        |> MapSet.new()

      # Find affected components (changed + children of changed + orphans needing parents)
      affected_components =
        all_components
        |> Enum.filter(fn component ->
          component.id in changed_ids_set ||
            parent_changed?(component, component_map, changed_module_names) ||
            orphan_needing_parent?(component, component_map)
        end)

      # Update parent relationships for affected components
      newly_updated_ids =
        affected_components
        |> Enum.map(&maybe_update_parent(scope, &1, component_map))
        |> Enum.reject(&is_nil/1)

      # Return expanded set: original changed + newly updated
      expanded_changed_ids = MapSet.union(changed_ids_set, MapSet.new(newly_updated_ids))
      {:ok, MapSet.to_list(expanded_changed_ids)}
    end
  rescue
    error ->
      Logger.error("Error during update_parent_relationships: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Synchronizes all components from spec files and implementation files.

  This is the backward-compatible interface that delegates to the new optimized functions.

  Module names come from:
  1. Implementation's declared module name (highest priority)
  2. Spec's H1 title
  3. Path-derived name (lowest priority)

  Component type comes from the spec's `## Type` section. If absent, nil.

  ## Options

  - `:base_dir` - Base directory to scan (defaults to current working directory)
  - `:force` - When true, ignores mtime and syncs all files (defaults to false)
  """
  @spec sync_all(Scope.t(), keyword()) ::
          {:ok, [Component.t()], [parse_error()]} | {:error, term()}
  def sync_all(%Scope{} = scope, opts \\ []) do
    # Delegate to new optimized functions
    with {:ok, all_components, changed_ids} <- sync_changed(scope, opts),
         {:ok, _expanded_ids} <-
           update_parent_relationships(scope, all_components, changed_ids, opts) do
      {:ok, all_components, []}
    end
  rescue
    error ->
      Logger.error("Error during sync_all: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Synchronizes a single component by module name.

  Looks up the expected spec and impl file paths for the module, parses any that
  exist, upserts the component, syncs its dependencies, and updates its parent
  relationship.

  Returns `{:ok, component}` or `{:error, reason}`.

  ## Options

  - `:base_dir` - Base directory (defaults to current working directory)
  """
  @spec sync_one(Scope.t(), String.t(), keyword()) ::
          {:ok, Component.t()} | {:error, term()}
  def sync_one(%Scope{} = scope, module_name, opts \\ []) when is_binary(module_name) do
    base_dir = Keyword.get(opts, :base_dir, ".")
    module_path = UtilPaths.module_to_path(module_name)

    spec_path = Path.join(base_dir, Paths.spec_file(module_path))
    impl_path = Path.join(base_dir, "lib/#{module_path}.ex")

    spec_data = if File.exists?(spec_path), do: parse_spec_file(FileInfo.from_path(spec_path), base_dir)
    impl_data = if File.exists?(impl_path), do: parse_impl_file(FileInfo.from_path(impl_path), base_dir)

    data =
      case {spec_data, impl_data} do
        {nil, nil} -> {:error, :no_files_found}
        {nil, impl} -> {:ok, impl}
        {spec, nil} -> {:ok, spec}
        {spec, impl} -> {:ok, merge_spec_impl(spec, impl)}
      end

    with {:ok, data} <- data do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      component = upsert_from_data(scope, data, now)

      # Sync dependencies using all project components for resolution
      all_components = Components.list_components(scope)
      sync_dependencies(scope, [data], all_components)

      # Update parent relationship
      component_map = Map.new(all_components, &{&1.module_name, &1})
      # Re-fetch after upsert to get the latest state
      component_map = Map.put(component_map, component.module_name, component)
      maybe_update_parent(scope, component, component_map)

      {:ok, component}
    end
  rescue
    error ->
      Logger.error("Error during sync_one for #{module_name}: #{inspect(error)}")
      {:error, error}
  end

  defp reject_ignored(merged_data, %MapSet{} = ignored) do
    if MapSet.size(ignored) == 0 do
      merged_data
    else
      Enum.reject(merged_data, &(&1.module_name in ignored))
    end
  end

  # --- File filtering (new optimization) ---

  defp filter_files_by_mtime(file_infos, changed_at_map, force, type, base_dir) do
    if force do
      {file_infos, []}
    else
      Enum.split_with(file_infos, &file_changed?(&1, changed_at_map, type, base_dir))
    end
  end

  defp file_changed?(file_info, changed_at_map, type, base_dir) do
    module_name = derive_module_from_path(file_info.path, base_dir, type)

    case Map.get(changed_at_map, module_name) do
      nil -> true
      changed_at -> DateTime.compare(file_info.mtime, changed_at) == :gt
    end
  end

  defp extract_module_names_from_paths(file_infos, base_dir, type) do
    Enum.map(file_infos, fn file_info ->
      derive_module_from_path(file_info.path, base_dir, type)
    end)
  end

  # --- Parsing ---

  defp parse_files(file_infos, parse_fn) do
    {successes, failures} =
      file_infos
      |> Enum.map(fn file_info ->
        try do
          {:ok, parse_fn.(file_info)}
        rescue
          error -> {:error, file_info.path, error}
        end
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    data = Enum.map(successes, fn {:ok, d} -> d end)
    errors = Enum.map(failures, fn {:error, path, err} -> {path, err} end)
    {data, errors}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp parse_spec_file(%FileInfo{path: path, mtime: mtime}, base_dir) do
    content = File.read!(path)

    # Validate H1 matches path (strict) - fail if mismatch
    case CodeMySpec.Documents.validate_h1_matches_path(content, path) do
      :ok -> :ok
      {:error, reason} -> raise "Spec validation failed: #{reason}"
    end

    # Validate internal dependencies exist - log warnings only
    case CodeMySpec.Documents.validate_internal_dependencies(content, base_dir) do
      {:ok, []} -> :ok
      {:ok, warnings} -> Enum.each(warnings, &log_validation_warning(path, &1))
    end

    # H1 is now validated to match path, so we can use it directly
    module_name = extract_h1_title(content)

    # Extract description from intro text (content after H1, before first H2)
    description = extract_intro_text(content)

    # Extract component type from ## Type section, falling back to namespace-derived type
    type = extract_type_section(content)

    # Extract dependencies from ## Dependencies section
    dependencies = extract_dependencies(content)

    %{
      module_name: module_name,
      type: type,
      description: description,
      dependencies: dependencies,
      spec_path: path,
      impl_path: nil,
      mtime: mtime
    }
  end

  defp log_validation_warning(path, message) do
    require Logger
    Logger.warning("[Spec Validation] #{path}: #{message}")
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp parse_impl_file(%FileInfo{path: path, mtime: mtime}, base_dir) do
    content = File.read!(path)

    module_name =
      case Regex.run(~r/defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
        [_, name] -> name
        _ -> derive_module_from_path(path, base_dir, :impl)
      end

    %{
      module_name: module_name,
      type: nil,
      description: nil,
      dependencies: [],
      spec_path: nil,
      impl_path: path,
      mtime: mtime
    }
  end

  defp extract_h1_title(content) do
    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, content) do
      [_, name] -> String.trim(name)
      _ -> nil
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

  defp extract_type_section(content) do
    # Try ## Type section first (canonical format)
    section_type =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    # Fall back to **Type**: value (legacy inline format)
    section_type ||
      case Regex.run(~r/^\*\*Type\*\*:\s*(.+)$/m, content) do
        [_, type] -> String.trim(type) |> String.downcase()
        nil -> nil
      end
  end

  defp extract_dependencies(content) do
    # Find the ## Dependencies section and extract module names
    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^## Dependencies/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(fn line ->
      line
      |> String.replace_prefix("- ", "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == "" || &1 == "None"))
  end

  defp derive_module_from_path(path, base_dir, :spec) do
    path
    |> String.replace_prefix("#{base_dir}/", "")
    |> String.replace_prefix(Paths.spec_prefix(), "")
    |> String.replace_suffix(".spec.md", "")
    |> path_to_module()
  end

  defp derive_module_from_path(path, base_dir, :impl) do
    path
    |> String.replace_prefix("#{base_dir}/", "")
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> path_to_module()
  end

  defp path_to_module(path) do
    path
    |> String.split("/")
    |> Enum.map_join(".", &camelize/1)
  end

  defp camelize(string) do
    string
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
  end

  # --- Merging ---

  defp merge_by_module_name(spec_data, impl_data) do
    spec_map = Map.new(spec_data, &{&1.module_name, &1})
    impl_map = Map.new(impl_data, &{&1.module_name, &1})

    all_names = MapSet.union(MapSet.new(Map.keys(spec_map)), MapSet.new(Map.keys(impl_map)))

    Enum.map(all_names, fn name ->
      spec = Map.get(spec_map, name)
      impl = Map.get(impl_map, name)

      case {spec, impl} do
        {nil, impl} -> impl
        {spec, nil} -> spec
        {spec, impl} -> merge_spec_impl(spec, impl)
      end
    end)
  end

  defp merge_spec_impl(spec, impl) do
    %{
      module_name: impl.module_name,
      type: spec.type || impl.type,
      description: spec.description,
      dependencies: spec.dependencies || [],
      spec_path: spec.spec_path,
      impl_path: impl.impl_path,
      mtime: latest_mtime(spec.mtime, impl.mtime)
    }
  end

  defp latest_mtime(nil, mtime), do: mtime
  defp latest_mtime(mtime, nil), do: mtime
  defp latest_mtime(m1, m2), do: if(DateTime.compare(m1, m2) == :gt, do: m1, else: m2)

  # --- Sync logic ---

  defp upsert_from_data(%Scope{} = scope, data, synced_at) do
    attrs =
      %{
        module_name: data.module_name,
        name: data.module_name |> String.split(".") |> List.last(),
        description: data.description,
        parent_component_id: nil,
        synced_at: synced_at,
        files_changed_at: data.mtime
      }
      |> maybe_put(:type, data.type)

    Components.upsert_component(scope, attrs)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Dependency syncing ---

  defp sync_dependencies(scope, changed_data, all_components) do
    component_map = Map.new(all_components, &{&1.module_name, &1})

    Enum.each(changed_data, fn data ->
      case Map.get(component_map, data.module_name) do
        nil -> :ok
        source -> sync_component_dependencies(scope, source, data, component_map)
      end
    end)
  end

  defp sync_component_dependencies(scope, source_component, data, component_map) do
    current_deps = Components.list_component_dependencies(scope, source_component.id)
    current_target_ids = MapSet.new(current_deps, & &1.target_component_id)

    declared_deps =
      (data.dependencies || [])
      |> Enum.map(&Map.get(component_map, &1))
      |> Enum.reject(&(is_nil(&1) || &1.id == source_component.id))

    declared_target_ids = MapSet.new(declared_deps, & &1.id)

    # Add new dependencies
    MapSet.difference(declared_target_ids, current_target_ids)
    |> Enum.each(fn target_id ->
      Components.create_dependency(scope, %{
        source_component_id: source_component.id,
        target_component_id: target_id
      })
    end)

    # Remove old dependencies that are no longer declared
    removed_deps = MapSet.difference(current_target_ids, declared_target_ids)

    Enum.each(current_deps, fn dep ->
      if dep.target_component_id in removed_deps do
        Components.delete_dependency(scope, dep)
      end
    end)
  end

  # --- Parent relationships (optimized) ---

  defp maybe_update_parent(scope, component, component_map) do
    new_parent = find_nearest_ancestor(component.module_name, component_map)

    cond do
      new_parent && new_parent.id != component.parent_component_id ->
        Components.update_component(scope, component, %{parent_component_id: new_parent.id})
        component.id

      is_nil(new_parent) && !is_nil(component.parent_component_id) ->
        Components.update_component(scope, component, %{parent_component_id: nil})
        component.id

      true ->
        nil
    end
  end

  defp parent_changed?(component, _component_map, changed_module_names) do
    parent_name = parent_module_name(component.module_name)
    parent_name && parent_name in changed_module_names
  end

  # A component with no parent_component_id that should have one (has an ancestor in the map)
  defp orphan_needing_parent?(component, component_map) do
    is_nil(component.parent_component_id) &&
      find_nearest_ancestor(component.module_name, component_map) != nil
  end

  defp derive_all_parent_relationships(scope, components) do
    component_map = Map.new(components, &{&1.module_name, &1})

    Enum.each(components, fn component ->
      case find_nearest_ancestor(component.module_name, component_map) do
        nil ->
          :ok

        parent when parent.id != component.id ->
          Components.update_component(scope, component, %{parent_component_id: parent.id})

        _ ->
          :ok
      end
    end)
  end

  # Walks up the module namespace tree to find the nearest existing ancestor.
  # For example, if "A.B.C.D" has no "A.B.C" component, it will check "A.B", then "A".
  defp find_nearest_ancestor(module_name, component_map) do
    case parent_module_name(module_name) do
      nil ->
        nil

      parent_name ->
        case Map.get(component_map, parent_name) do
          nil -> find_nearest_ancestor(parent_name, component_map)
          parent -> parent
        end
    end
  end

  defp parent_module_name(module_name) do
    parts = String.split(module_name, ".")

    if length(parts) > 1 do
      parts |> Enum.drop(-1) |> Enum.join(".")
    else
      nil
    end
  end

  defp cleanup_removed(%Scope{} = scope, existing, current_names) do
    existing
    |> Enum.reject(&(&1.module_name in current_names))
    |> Enum.each(&Components.delete_component(scope, &1))
  end

  defp cleanup_ignored(%Scope{} = scope, %MapSet{} = ignored) do
    if MapSet.size(ignored) == 0 do
      :ok
    else
      Components.list_components(scope)
      |> Enum.filter(&(&1.module_name in ignored))
      |> Enum.each(fn component ->
        Logger.info("[Sync] Deleting ignored component: #{component.module_name}")
        Components.delete_component(scope, component)
      end)
    end
  end
end
