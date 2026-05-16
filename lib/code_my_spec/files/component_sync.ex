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
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.FileSync
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
  - `:base_dir` — accepted for backwards compatibility, ignored. File content
    is read via `scope.environment` so the dispatcher can route to in-memory
    implementations for tests.
  - `:changed_paths` — when provided, only process files matching these paths (incremental sync)
  """
  @spec sync_from_files(Scope.t(), keyword()) :: {:ok, sync_result()}
  def sync_from_files(%Scope{} = scope, opts \\ []) do
    _ = Keyword.get(opts, :base_dir)
    changed_paths = Keyword.get(opts, :changed_paths)
    incremental? = is_list(changed_paths)
    start = System.monotonic_time(:millisecond)
    env = scope.environment

    {spec_files, impl_files} = query_files(scope, changed_paths)

    # `infrastructure_paths` classifies framework-generated modules as
    # `type: "infrastructure"` — components for them get an empty
    # requirement graph, so no agent work is driven. The classifier wins
    # over the impl-only type fallback (`module`) but loses to an
    # explicit type written in a spec file (the architect's word is
    # authoritative when present).
    infra_paths = FileSync.load_infrastructure_paths(scope)

    spec_data =
      spec_files
      |> Enum.map(&parse_spec_file(&1, env))
      |> Enum.reject(&is_nil/1)

    impl_data =
      impl_files
      |> Enum.map(&parse_impl_file(&1, env, infra_paths))
      |> Enum.reject(&is_nil/1)

    merged = merge_by_module_name(spec_data, impl_data)

    if merged == [] do
      ms = System.monotonic_time(:millisecond) - start
      Logger.info("[Files.ComponentSync] No components to sync (#{ms}ms)")
      {:ok, %{all_components: [], changed_component_ids: []}}
    else
      do_sync(scope, merged, incremental?, start)
    end
  end

  defp query_files(%Scope{active_project_id: project_id}, changed_paths) when is_list(changed_paths) do
    {
      File
      |> where([f], f.project_id == ^project_id and f.role == :spec and f.path in ^changed_paths)
      |> Repo.all(),
      File
      |> where([f], f.project_id == ^project_id and f.role == :implementation and f.path in ^changed_paths)
      |> Repo.all()
    }
  end

  defp query_files(%Scope{active_project_id: project_id}, _changed_paths) do
    {
      File |> where([f], f.project_id == ^project_id and f.role == :spec) |> Repo.all(),
      File |> where([f], f.project_id == ^project_id and f.role == :implementation) |> Repo.all()
    }
  end

  defp do_sync(scope, merged, incremental?, start) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    existing_components = Components.list_components(scope)
    existing_map = Map.new(existing_components, &{&1.module_name, &1})

    synced_components = Enum.map(merged, &upsert_component(scope, &1, now))

    component_map =
      Map.merge(existing_map, Map.new(synced_components, &{&1.module_name, &1}))

    changed_component_ids = compute_changed_ids(synced_components, existing_map)

    update_parent_relationships(scope, synced_components, component_map)
    sync_dependencies(scope, merged, component_map)

    unless incremental? do
      all_module_names = MapSet.new(merged, & &1.module_name)
      cleanup_removed(scope, existing_components, all_module_names)
    end

    affected_map = Map.new(synced_components, &{&1.module_name, &1})
    backfill_file_owners(scope, affected_map)

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

  defp compute_changed_ids(synced_components, existing_map) do
    synced_components
    |> Enum.filter(&component_changed?(&1, existing_map))
    |> Enum.map(& &1.id)
  end

  defp component_changed?(component, existing_map) do
    case Map.get(existing_map, component.module_name) do
      nil -> true
      existing -> existing.updated_at != component.updated_at
    end
  end

  # -- Spec parsing --

  # Spec files: the H1 line (e.g. `# CodeMySpec.Git.Behaviour`) is the
  # authoritative module identifier. Path is purely storage — the file
  # can live anywhere; the H1 inside is what names it.
  defp parse_spec_file(%File{path: path} = _file, env) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        case extract_h1_module(content) do
          nil ->
            nil

          name ->
            %{
              module_name: name,
              type: extract_type_section(content),
              description: extract_intro_text(content),
              dependencies: extract_dependencies(content)
            }
        end

      {:error, _} ->
        nil
    end
  end

  # Impl files: the `defmodule X do` declaration is the authoritative
  # module identifier. Path is purely storage. Files without a
  # `defmodule` line (scripts, .exs, etc.) are skipped.
  defp parse_impl_file(%File{path: path} = _file, env, infra_paths) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        case Regex.run(~r/^defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
          [_, name] ->
            type =
              if FileSync.infrastructure_path?(path, infra_paths),
                do: "infrastructure",
                else: nil

            %{module_name: name, type: type, description: nil, dependencies: []}

          _ ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp extract_h1_module(content) do
    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, content) do
      [_, name] -> name
      _ -> nil
    end
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
    Enum.each(components, &reparent_component(scope, &1, component_map))
  end

  defp reparent_component(scope, component, component_map) do
    case find_nearest_ancestor(component.module_name, component_map) do
      nil -> maybe_clear_parent(scope, component)
      parent when parent.id != component.id -> maybe_set_parent(scope, component, parent)
      _ -> :ok
    end
  end

  defp maybe_clear_parent(_scope, %{parent_component_id: nil}), do: :ok

  defp maybe_clear_parent(scope, component) do
    Components.update_component(scope, component, %{parent_component_id: nil})
  end

  defp maybe_set_parent(_scope, %{parent_component_id: same_id}, %{id: same_id}), do: :ok

  defp maybe_set_parent(scope, component, parent) do
    Components.update_component(scope, component, %{parent_component_id: parent.id})
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
    Enum.each(component_map, fn {module_name, component} ->
      module_path = module_name_to_path(module_name)
      source_path = source_path_for_type(module_path, component.type)

      patterns = [
        Paths.spec_dir() <> "/#{module_path}.spec.md",
        Paths.spec_dir() <> "/#{module_path}/design_review.md",
        "lib/#{source_path}.ex",
        "test/#{source_path}_test.exs"
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

  # Phoenix convention: LiveViews live in `live/`, controllers in `controllers/`
  defp source_path_for_type(module_path, type) when type in ["liveview", "liveview_component", "live_context"] do
    inject_dir_segment(module_path, "live")
  end

  defp source_path_for_type(module_path, type) when type in ["controller", "json"] do
    inject_dir_segment(module_path, "controllers")
  end

  defp source_path_for_type(module_path, _type), do: module_path

  # Insert a directory segment after the first path component.
  # "metric_flow_web/dashboard_live/show" → "metric_flow_web/live/dashboard_live/show"
  defp inject_dir_segment(path, dir) do
    case String.split(path, "/", parts: 2) do
      [first, rest] -> "#{first}/#{dir}/#{rest}"
      [single] -> "#{single}/#{dir}"
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
