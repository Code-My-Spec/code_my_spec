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
  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.{ComponentExtract, File}
  alias CodeMySpec.Harnesses
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

    # Story 892. Reclaim before projecting, so components are projected from what
    # live agents actually hold rather than from the leavings of agents that are
    # gone.
    #
    # Here rather than on a schedule because components are where the damage shows
    # and this is where someone is asking about them. A project nobody is touching
    # has nobody blocked; reclaiming exactly when someone needs the answer needs no
    # scheduler at all — and a scheduler would not have helped the case this comes
    # from, where every remaining harness was stale.
    Harnesses.reclaim_quiet(scope)

    {spec_files, impl_files} = query_files(scope, changed_paths)

    parsed_specs = Enum.map(spec_files, &parse_spec_file(&1, env))
    unreadable = Enum.count(parsed_specs, &(&1 == :unreadable))

    spec_data = Enum.reject(parsed_specs, &(is_nil(&1) or &1 == :unreadable))

    impl_data =
      impl_files
      |> Enum.map(&parse_impl_file(&1, env))
      |> Enum.reject(&is_nil/1)

    merged = merge_by_module_name(spec_data, impl_data)

    if merged == [] do
      ms = System.monotonic_time(:millisecond) - start
      Logger.info("[Files.ComponentSync] No components to sync (#{ms}ms)")
      {:ok, %{all_components: [], changed_component_ids: []}}
    else
      do_sync(scope, merged, incremental? or unreadable > 0, start, unreadable)
    end
  end

  defp query_files(%Scope{active_project_id: project_id}, changed_paths)
       when is_list(changed_paths) do
    {
      File
      |> where([f], f.project_id == ^project_id and f.role == :spec and f.path in ^changed_paths)
      |> Repo.all(),
      File
      |> where(
        [f],
        f.project_id == ^project_id and f.role == :implementation and f.path in ^changed_paths
      )
      |> Repo.all()
    }
  end

  # Project-wide, deliberately — every checkout's files, not this one's.
  #
  # `Files.list_files/1` and the requirement preloader are both harness-scoped,
  # so this reads like one that was missed. It is not, and scoping it would be a
  # data-loss bug: `cleanup_removed/3` deletes a component whose module name is
  # absent from what this query returned, so a per-harness read would have every
  # sync delete every component whose spec lives only in another checkout.
  # Three working copies syncing in turn would take turns deleting each other's
  # architecture.
  #
  # The two questions are different and both are answered correctly today.
  # *Identity* — does this project have a component called `X` — is project-wide,
  # because a component id is stable and 112 stories and 4048 requirements link
  # to one. *Presence* — does this checkout have a spec for it — is per harness,
  # and `ArchitectureChecker.orphans/1` asks `Files.component_ids_present/1` for
  # exactly that.
  #
  # So a component survives while any checkout still carries its spec, and is
  # only somebody's orphan in the checkout that has the file to resolve it with.
  defp query_files(%Scope{active_project_id: project_id}, _changed_paths) do
    {
      File |> where([f], f.project_id == ^project_id and f.role == :spec) |> Repo.all(),
      File |> where([f], f.project_id == ^project_id and f.role == :implementation) |> Repo.all()
    }
  end

  # `incremental?` also covers "a spec could not be read", because both mean the
  # same thing to `cleanup_removed/3`: this run does not know the full set, so it
  # must not delete anything for being missing from it.
  #
  # On the light harness the server holds no working copy, so a spec without
  # scanner-stored data reads as `{:error, :no_environment}` and the component it
  # names is simply absent from `merged`. A full sync then deleted it —
  # destroying architecture state because a file could not be opened. Measured:
  # 904 of 904 components resynced with `:no_environment` warnings throughout,
  # and the only reason nothing was lost is that 1494 of 1519 specs carry parsed
  # data from the scanner and never reach the disk path at all.
  #
  # Refusing to prune on an incomplete picture is the same rule the harness
  # already applies to an empty scan, and for the same reason: sending it "would
  # have deleted every file this project has on the server".
  defp do_sync(scope, merged, incremental?, start, unreadable) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    existing_components = Components.list_components(scope)
    existing_map = Map.new(existing_components, &{&1.module_name, &1})

    synced_components = Enum.map(merged, &upsert_component(scope, &1, now, existing_map))

    component_map =
      Map.merge(existing_map, Map.new(synced_components, &{&1.module_name, &1}))

    changed_component_ids = compute_changed_ids(synced_components, existing_map)

    update_parent_relationships(scope, synced_components, component_map)
    sync_dependencies(scope, merged, component_map)

    if unreadable > 0 do
      Logger.warning(
        "[Files.ComponentSync] #{unreadable} spec file(s) could not be read; skipping cleanup. " <>
          "A component missing from an incomplete sync is unknown, not deleted — see the " <>
          "per-file warnings above for which."
      )
    end

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
  # Prefers what the scan already worked out. `Files.Scanner` extracts the
  # component's identity while it has the bytes, so this needs no disk — which
  # is the point, because on the light harness there is none, and a spec that
  # cannot be read is indistinguishable here from a component that no longer
  # exists. `cleanup_removed/3` then prunes it.
  #
  # Falls back to reading for File rows written before the scanner stored this.
  defp parse_spec_file(%File{validation_errors: errors} = file, env) do
    case stored_component_data(errors) do
      %{"module_name" => name} = data when is_binary(name) ->
        %{
          module_name: name,
          type: data["type"],
          description: data["description"],
          dependencies: data["dependencies"] || []
        }

      _ ->
        parse_spec_file_from_disk(file, env)
    end
  end

  defp stored_component_data(%{"data" => data}) when is_map(data), do: data
  defp stored_component_data(_), do: nil

  defp parse_spec_file_from_disk(%File{path: path} = _file, env) do
    case Environments.read_file(env, path) do
      {:ok, raw_content} ->
        # Normalize CRLF → LF before regex extraction. Spec files written
        # or edited on Windows carry `\r\n`; the `$`-anchored extractors
        # (extract_h1_module, extract_type_section, …) otherwise fail to
        # match because the `\r` sits between the value and the line end,
        # so the component silently never materializes from its spec.
        content = String.replace(raw_content, "\r\n", "\n")

        case extract_h1_module(content) do
          nil ->
            # A spec file is present on disk but yields no module name. The
            # component it should describe will be ABSENT from `merged`, and a
            # full sync's `cleanup_removed/3` will then DELETE that component —
            # silently destroying architecture state (this is exactly how a CRLF
            # H1 regression manifested: the `$`-anchored extractor matched
            # nothing). Never let this pass unlogged.
            Logger.warning(
              "[Files.ComponentSync] spec file #{path} has no extractable H1 module heading; " <>
                "its component will not be synced and may be pruned. Check the `# Module.Name` line."
            )

            nil

          name ->
            %{
              module_name: name,
              type: extract_type_section(content),
              description: extract_intro_text(content),
              dependencies: extract_dependencies(content)
            }
        end

      {:error, reason} ->
        Logger.warning(
          "[Files.ComponentSync] could not read spec file #{path} (#{inspect(reason)}); " <>
            "its component is unknown to this sync, which will therefore not prune."
        )

        # `:unreadable`, not `nil`. Both keep the component out of `merged`, but
        # only this one says the sync's picture is incomplete — and that is what
        # stops `cleanup_removed/3` deleting a component for being absent from a
        # list that could not be built.
        :unreadable
    end
  end

  # Impl files: the `defmodule X do` declaration is the authoritative
  # module identifier. Path is purely storage. Files without a
  # `defmodule` line (scripts, .exs, etc.) are skipped. Type is never
  # inferred from impl content — it lives in the spec (and may move to
  # a module attribute later). Type defaults are owned by
  # `Components.upsert_component`.
  defp parse_impl_file(%File{validation_errors: errors} = file, env) do
    case stored_component_data(errors) do
      %{"module_name" => name} = data when is_binary(name) ->
        %{module_name: name, type: impl_type(data), description: nil, dependencies: []}

      # An impl file with no defmodule (a script, an .exs) has no component
      # identity, and the scan recorded that as an explicit nil. Distinguish it
      # from "nothing stored yet" so a known-empty answer is not re-derived by
      # opening the file.
      %{"module_name" => nil} ->
        nil

      _ ->
        parse_impl_file_from_disk(file, env)
    end
  end

  # The one type an implementation is allowed to claim. Everything else still
  # comes from the spec's `## Type`, and the merge below prefers the spec — so
  # an explicit declaration always wins and nothing already correct moves.
  #
  # A row scanned before `ecto_schema` was recorded has no such key, which reads
  # as `nil` and yields no type. That is the same answer it gave before, so the
  # backfill is whatever the next scan of that file produces rather than a
  # migration.
  defp impl_type(%{"ecto_schema" => true}), do: "schema"
  defp impl_type(_data), do: nil

  defp parse_impl_file_from_disk(%File{path: path} = _file, env) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        case Regex.run(~r/^defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
          [_, name] ->
            %{
              module_name: name,
              type: impl_type(%{"ecto_schema" => ComponentExtract.ecto_schema?(content)}),
              description: nil,
              dependencies: []
            }

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
      spec = Map.get(spec_map, name)
      impl = Map.get(impl_map, name)

      # `dependencies: nil` is the "no spec file present" signal that
      # `sync_component_dependencies/4` uses to leave the component's deps
      # untouched. With a spec file present, the spec's list (possibly `[]`)
      # is authoritative.
      %{
        module_name: name,
        type: (spec && spec.type) || (impl && impl.type),
        description: (spec && spec.description) || (impl && impl.description),
        dependencies: spec && spec.dependencies
      }
    end)
  end

  # -- Upsert --

  # Splits into create-or-update so a sync that lacks new type info (impl
  # file without a matching spec, which is the dominant case during early
  # generation) doesn't clobber an existing component's type with the
  # `Component.changeset` default of `"module"`. The previous
  # `upsert_component` path always went through `Repo.insert(..., on_conflict:
  # {:replace_all_except, [...]})`, and the insertion's changeset carried
  # the default type — which then overwrote the existing row's user-set type
  # (e.g. "schema" → "module"), reshaping the component's requirement graph.
  defp upsert_component(%Scope{} = scope, data, synced_at, existing_map) do
    attrs =
      %{
        module_name: data.module_name,
        name: data.module_name |> String.split(".") |> List.last(),
        description: data.description,
        synced_at: synced_at
      }
      |> maybe_put(:type, data.type)

    case Map.get(existing_map, data.module_name) do
      nil ->
        Components.upsert_component(scope, attrs)

      existing ->
        {:ok, updated} = Components.update_component(scope, existing, attrs)
        updated
    end
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

  # `data.dependencies == nil` means we have no spec file for this
  # component — leave deps alone rather than wiping the user/agent-set
  # graph. A spec file with no `## Dependencies` section parses to `[]`
  # and IS authoritative (sync to empty).
  defp sync_component_dependencies(_scope, _source, %{dependencies: nil}, _component_map), do: :ok

  defp sync_component_dependencies(scope, source, data, component_map) do
    current_deps = Components.list_component_dependencies(scope, source.id)
    current_target_ids = MapSet.new(current_deps, & &1.target_component_id)

    declared_deps =
      data.dependencies
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
      # One source for these, shared with `Files.read_model/1`, which indexes
      # components by the same paths so ownership is a lookup rather than a
      # path → module guess. Two copies drifted once already: this claim set
      # `component_id` and the guess wrote `nil` back over it on every scan
      # (`d698ab0e`).
      patterns =
        ConventionalPaths.for_component(%{module_name: module_name, type: component.type})

      File
      |> where(
        [f],
        f.project_id == ^project_id and f.path in ^patterns and is_nil(f.component_id)
      )
      |> Repo.update_all(set: [component_id: component.id])

      # Path patterns only find files where Phoenix puts a module where its name
      # suggests, and it often does not: `MyAppWeb.CoreComponents` lives under
      # `components/`, `MyAppWeb.ErrorHTML` under `controllers/`. Those files are
      # then owned by nothing and their `implementation_file` requirement cannot
      # be satisfied by any correct work — the QA drill hit four and rightly
      # refused to relocate framework files to please a checker.
      #
      # The scan already recorded the `defmodule` each implementation declares,
      # so claim by that too. Still `is_nil(component_id)`, so a file already
      # owned is never stolen.
      File
      |> where(
        [f],
        f.project_id == ^project_id and f.role == :implementation and
          is_nil(f.component_id) and
          fragment("?->'data'->>'module_name' = ?", f.validation_errors, ^module_name)
      )
      |> Repo.update_all(set: [component_id: component.id])
    end)
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
