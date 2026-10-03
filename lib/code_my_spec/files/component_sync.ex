defmodule CodeMySpec.Files.ComponentSync do
  @moduledoc """
  Keeps a project's components in step with its code.

  Components are records (3aeb66cf): their type, description, parent and
  dependencies are authored through the tools, and no file describes them. A
  sync only reconciles what *exists* against live code:

  1. A module main's code declares, with no component, is created as
     `:discovered` under its nearest ancestor.
  2. A component that predates provenance and is named by main's code becomes
     `:discovered`; one nothing names is left for a person to decide.
  3. A `:discovered` component main's code no longer names is pruned, unless an
     authored dependency or a story points at it.
  4. Files are linked to the component they belong to.

  "Main's code" is `Files.LiveCopies.speaking_ids/1`: the main copy, or every
  live checkout when the project has none (14f4f837). A feature copy's new
  module is discovered once it is promoted. Spec files play no part.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.{ComponentExtract, File, LiveCopies}
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type sync_result :: %{
          all_components: [Component.t()],
          changed_component_ids: [Ecto.UUID.t()]
        }

  @doc """
  Sync components from File records.

  ## Options
  - `:base_dir` — accepted for backwards compatibility, ignored. File content
    is read via `scope.environment` so the dispatcher can route to in-memory
    implementations for tests.
  - `:changed_paths` — when provided, only process files matching these paths (incremental sync)
  - `:removed_module_names` — module names named by implementation files that
    were just removed (see `removed_module_names/1`). An incremental sync never
    reads the files that *didn't* change, so it cannot rebuild the full set
    `cleanup_removed/2` diffs against; each name here is checked against live
    code instead.
  """
  @spec sync_from_files(Scope.t(), keyword()) :: {:ok, sync_result()}
  def sync_from_files(%Scope{} = scope, opts \\ []) do
    _ = Keyword.get(opts, :base_dir)
    changed_paths = Keyword.get(opts, :changed_paths)
    removed_module_names = Keyword.get(opts, :removed_module_names, [])
    start = System.monotonic_time(:millisecond)

    # Only main's code says what exists — a feature copy's unpromoted module and
    # a stale worktree's deleted one are neither created nor kept on its word.
    live_files =
      scope
      |> query_files(changed_paths)
      |> live_only(scope.active_project_id)

    code =
      live_files
      |> Enum.map(&parse_impl_file(&1, scope.environment))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.module_name)

    do_sync(scope, code, live_files, is_list(changed_paths), start, removed_module_names)
  end

  @doc """
  Module names named by files that are gone — worth checking whether their
  component is now orphaned.

  Called by `FileSync` right after a reconcile removes rows, on the removed
  records themselves (their old `validation_errors` still carry whatever
  module name the scanner last stored for them, same as a live file's does).
  A file with no stored module name — `:test`/doc roles, or a row scanned
  before this was recorded — contributes nothing, the same way it contributes
  nothing to `merge_by_module_name/2` for a live file.
  """
  @spec removed_module_names([File.t()]) :: [String.t()]
  def removed_module_names(removed_records) do
    removed_records
    |> Enum.filter(&(&1.role == :implementation))
    |> Enum.flat_map(&removed_module_name/1)
    |> Enum.uniq()
  end

  defp removed_module_name(%File{validation_errors: errors}) do
    case stored_component_data(errors) do
      %{"module_name" => name} when is_binary(name) -> [name]
      _ -> []
    end
  end

  defp query_files(%Scope{active_project_id: project_id}, changed_paths)
       when is_list(changed_paths) do
    File
    |> where(
      [f],
      f.project_id == ^project_id and f.role == :implementation and f.path in ^changed_paths
    )
    |> Repo.all()
  end

  # Project-wide, deliberately — main's code, not this checkout's: a sync from a
  # feature copy still answers for the project.
  defp query_files(%Scope{active_project_id: project_id}, _changed_paths) do
    File |> where([f], f.project_id == ^project_id and f.role == :implementation) |> Repo.all()
  end

  defp do_sync(scope, code, live_files, incremental?, start, removed_module_names) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    existing_components = Components.list_components(scope)
    existing_map = Map.new(existing_components, &{&1.module_name, &1})

    synced_components = Enum.map(code, &adopt_component(scope, &1, now, existing_map))

    component_map =
      Map.merge(existing_map, Map.new(synced_components, &{&1.module_name, &1}))

    changed_component_ids = compute_changed_ids(synced_components, existing_map)
    announced_component_ids = compute_announced_ids(synced_components, existing_map)

    # Only what this sync created gets a derived parent; an existing record's
    # parent was authored, or set when it was discovered.
    synced_components
    |> Enum.reject(&Map.has_key?(existing_map, &1.module_name))
    |> then(&update_parent_relationships(scope, &1, component_map))

    sync_discovered_dependencies(scope, live_files, component_map, incremental?)

    cond do
      not incremental? ->
        cleanup_removed(scope, existing_components)

      removed_module_names != [] ->
        cleanup_orphaned(scope, removed_module_names, existing_map)

      true ->
        :ok
    end

    affected_map = Map.new(synced_components, &{&1.module_name, &1})
    backfill_file_owners(scope, affected_map)

    ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[Files.ComponentSync] #{length(synced_components)} components synced in #{ms}ms " <>
        "(#{length(changed_component_ids)} changed)"
    )

    announce_graph_change(scope, announced_component_ids)

    {:ok,
     %{
       all_components: synced_components,
       changed_component_ids: changed_component_ids
     }}
  end

  # Components are the entities that carry `implementation_file`, so creating
  # or changing one moves the graph — and this said nothing.
  #
  # `FileSync` announcing was not cover for it, and the order is why:
  # `FilesLive.do_sync/2` runs `FileSync.sync/2` and *then*
  # `ComponentSync.sync_from_files/2`, and `FileSync` announces at the end of
  # its own pass. So the announcement goes out while the files exist and the
  # components they belong to do not. A recompute that lands in that window
  # answers from a half-applied sync, clears the queue, and nothing tells the
  # graph the components arrived.
  #
  # Reproduced on criterion 3346 at a 25ms debounce: 2 failures in 5 runs, with
  # `spec_file` false against a spec file that was plainly a row with the right
  # role and the right component. Invisible before reads stopped recomputing,
  # because the next reader rebuilt the graph and got it right.
  #
  # Nothing changed means nothing to say: a scan that re-reads 5,000 files and
  # finds every component identical is the common case, and announcing it would
  # cost a preload per scan to discover that.
  defp announce_graph_change(_scope, []), do: :ok

  # The components that actually changed, which this already worked out and was
  # throwing away — `compute_changed_ids/2` exists to decide whether to announce
  # at all, and the same list answers *what* moved.
  #
  # Not `:project`: `architecture_designed` is settled by the `files_synced`
  # handler that follows every scan, from the `:architecture` profile. A
  # `:project` entity sent every vantage through the project's own recompute
  # instead — the orphan scan over every component, ten times per scan.
  #
  # Project-wide, because what this scan changed is the component *rows* —
  # type, parent, description — and those are read by every checkout's
  # projection. Marked for this checkout, the event path settled only this
  # checkout and the others kept the component they knew before; the files
  # behind the same scan are per checkout and arrive as `files_synced`.
  defp announce_graph_change(scope, announced_component_ids),
    do:
      GraphInputs.announce(
        scope,
        "Files.ComponentSync",
        Enum.map(announced_component_ids, &{"component", &1}),
        :project_wide
      )

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

  # What the graph hears: the components whose *type* changed, or that are
  # new. `changed_component_ids` means "rows written"; the graph reads a
  # component's type, parent and name and nothing else. The parent is resolved
  # after this and announced by `Components.update_component/4` on its own
  # terms.
  defp compute_announced_ids(synced_components, existing_map) do
    synced_components
    |> Enum.filter(fn component ->
      case Map.get(existing_map, component.module_name) do
        nil -> true
        existing -> existing.type != component.type
      end
    end)
    |> Enum.map(& &1.id)
  end

  # -- Code parsing --

  defp stored_component_data(%{"data" => data}) when is_map(data), do: data
  defp stored_component_data(_), do: nil

  # Impl files: the `defmodule X do` declaration is the authoritative
  # module identifier. Path is purely storage. Files without a
  # `defmodule` line (scripts, .exs, etc.) are skipped. A new component's
  # type defaults in `Components.upsert_component`, except a schema, which
  # code can say.
  defp parse_impl_file(%File{validation_errors: errors} = file, env) do
    case stored_component_data(errors) do
      %{"module_name" => name} = data when is_binary(name) ->
        %{module_name: name, type: impl_type(data)}

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

  # The one type code can claim, and only for a component it creates. A row
  # scanned before `ecto_schema` was recorded has no such key and yields no
  # type.
  defp impl_type(%{"ecto_schema" => true}), do: "schema"
  defp impl_type(_data), do: nil

  defp parse_impl_file_from_disk(%File{path: path} = _file, env) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        case Regex.run(~r/^defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
          [_, name] ->
            %{
              module_name: name,
              type: impl_type(%{"ecto_schema" => ComponentExtract.ecto_schema?(content)})
            }

          _ ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  # -- Discovered dependencies --

  # A dependency code itself names, by `alias` crossing contexts. Only a full
  # sync recomputes this: an incremental sync touches one changed file and
  # cannot tell whether some *other* live file still names a pair it did not
  # touch, so it leaves `in_code` as it found it.
  defp sync_discovered_dependencies(_scope, _live_files, _component_map, true), do: :ok

  defp sync_discovered_dependencies(scope, live_files, component_map, false) do
    by_id = Map.new(Map.values(component_map), &{&1.id, &1})

    found =
      live_files
      |> Enum.flat_map(&dependency_pairs(&1, scope.environment, component_map, by_id))
      |> MapSet.new()

    reconcile_discovered_dependencies(scope, found)
  end

  # The source is the file's own module; targets are whatever it `alias`es
  # that both name an existing component and sit in a different context. A
  # name `alias` names that no component matches (an external lib, a typo)
  # resolves to nothing and is silently dropped — the same posture
  # `parse_impl_file_from_disk/2` takes on a file with no `defmodule`.
  defp dependency_pairs(%File{path: path}, env, component_map, by_id) do
    with {:ok, content} <- Environments.read_file(env, path),
         name when is_binary(name) <- ComponentExtract.extract_defmodule(content),
         %Component{} = source <- Map.get(component_map, name) do
      content
      |> ComponentExtract.extract_aliases()
      |> Enum.map(&Map.get(component_map, &1))
      |> Enum.reject(fn target ->
        is_nil(target) or target.id == source.id or
          owning_context_id(source, by_id) == owning_context_id(target, by_id)
      end)
      |> Enum.map(&{source.id, &1.id})
    else
      _ -> []
    end
  end

  # A context names itself; anything else climbs to the nearest ancestor that
  # does, the same reach `ConventionalPaths` and `format_context_section`
  # assume a child always has. A component with no context ancestor (a root
  # component outside any context) stands for itself — there is no context to
  # collapse into.
  defp owning_context_id(%Component{type: "context", id: id}, _by_id), do: id
  defp owning_context_id(%Component{parent_component_id: nil, id: id}, _by_id), do: id

  defp owning_context_id(%Component{parent_component_id: parent_id} = component, by_id) do
    case Map.get(by_id, parent_id) do
      nil -> component.id
      parent -> owning_context_id(parent, by_id)
    end
  end

  # Mirrors `cleanup_removed/2`'s shape for components: a pair live code still
  # names is upserted `in_code: true`; a pair it no longer names loses the
  # flag, and a row that was never anything but the code's own claim
  # (`:discovered`) is removed outright rather than left as a lone `false`.
  # An `:authored` row is never deleted here — a planned edge outlives the
  # code catching up to it, same as `cleanup_removed/2` never prunes an
  # authored component.
  defp reconcile_discovered_dependencies(scope, found) do
    existing =
      scope
      |> Components.list_dependencies()
      |> Map.new(&{{&1.source_component_id, &1.target_component_id}, &1})

    Enum.each(found, fn {source_id, target_id} = pair ->
      case Map.get(existing, pair) do
        nil ->
          Components.create_dependency(scope, %{
            source_component_id: source_id,
            target_component_id: target_id,
            provenance: :discovered,
            in_code: true
          })

        %Dependency{in_code: true} ->
          :ok

        dependency ->
          Components.update_dependency(scope, dependency, %{in_code: true})
      end
    end)

    existing
    |> Map.values()
    |> Enum.filter(&stale_in_code?(&1, found))
    |> Enum.each(&retire_discovered_dependency(scope, &1))
  end

  defp stale_in_code?(dependency, found) do
    dependency.in_code and
      not MapSet.member?(found, {dependency.source_component_id, dependency.target_component_id})
  end

  defp retire_discovered_dependency(scope, %Dependency{provenance: :discovered} = dependency),
    do: Components.delete_dependency(scope, dependency)

  defp retire_discovered_dependency(scope, dependency),
    do: Components.update_dependency(scope, dependency, %{in_code: false})

  # -- Upsert --

  # An existing component is the record and is not touched: its description,
  # type and parent are authored or were set when it was discovered. A module
  # code names that has no component is new, and is created as discovered. One
  # that predates provenance is code's too, so it becomes discovered.
  defp adopt_component(scope, data, synced_at, existing_map) do
    case Map.get(existing_map, data.module_name) do
      nil ->
        Components.upsert_component(
          scope,
          %{
            module_name: data.module_name,
            name: data.module_name |> String.split(".") |> List.last(),
            synced_at: synced_at,
            provenance: :discovered
          }
          |> maybe_put(:type, data.type)
        )

      %{provenance: nil} = existing ->
        existing |> Ecto.Changeset.change(provenance: :discovered) |> Repo.update!()

      existing ->
        existing
    end
  end

  defp live_only(files, project_id) do
    speaking = MapSet.new(LiveCopies.speaking_ids(project_id))
    Enum.filter(files, &MapSet.member?(speaking, &1.working_copy_id))
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

  # -- Cleanup --

  # Only a discovered component goes — it existed because code named it — and
  # only once main's code no longer names it, whatever a stale or feature copy
  # still holds (14f4f837). An authored component is the intended
  # architecture whether or not code exists yet, and an unmarked one is left
  # for a person to decide; only `delete_component` removes either.
  defp cleanup_removed(%Scope{active_project_id: project_id} = scope, existing) do
    claimed = live_claimed_names(project_id)

    existing
    |> Enum.filter(
      &(&1.provenance == :discovered and not MapSet.member?(claimed, &1.module_name))
    )
    |> prune_unreferenced(scope)
  end

  # `cleanup_removed/2`'s incremental counterpart: only the removed files'
  # module names are candidates.
  defp cleanup_orphaned(%Scope{active_project_id: project_id} = scope, module_names, existing_map) do
    claimed = live_claimed_names(project_id)

    module_names
    |> Enum.map(&Map.get(existing_map, &1))
    |> Enum.filter(
      &((&1 && &1.provenance == :discovered) and not MapSet.member?(claimed, &1.module_name))
    )
    |> prune_unreferenced(scope)
  end

  # Only code claims a component, and only main's code.
  defp live_claimed_names(project_id) do
    live_ids = LiveCopies.speaking_ids(project_id)

    from(f in File,
      where:
        f.project_id == ^project_id and f.role == :implementation and
          f.working_copy_id in ^live_ids,
      select: fragment("?->'data'->>'module_name'", f.validation_errors)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # A discovered component an authored dependency or a story still points at
  # is kept and said, rather than deleted out from under them.
  defp prune_unreferenced(components, scope) do
    {kept, pruned} = Enum.split_with(components, &referenced?/1)

    if kept != [] do
      Logger.warning(
        "[Files.ComponentSync] kept #{length(kept)} discovered component(s) whose code is " <>
          "gone because something authored still points at them: " <>
          Enum.map_join(kept, ", ", & &1.module_name)
      )
    end

    Enum.each(pruned, &Components.delete_component(scope, &1))
  end

  defp referenced?(%Component{id: id}) do
    Repo.exists?(
      from(d in Dependency,
        where:
          d.provenance == :authored and
            (d.source_component_id == ^id or d.target_component_id == ^id)
      )
    ) or Repo.exists?(from(s in Story, where: s.component_id == ^id))
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
end
