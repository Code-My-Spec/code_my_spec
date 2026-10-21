defmodule CodeMySpec.Files.ComponentSync do
  @moduledoc """
  Keeps a project's components in step with its code.

  Components are records: their type, description, parent and
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
  live checkout when the project has none. A feature copy's new
  module is discovered once it is promoted. Spec files play no part.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.{ComponentExtract, DependencyEvidence, File, LiveCopies}
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @type sync_result :: %{
          all_components: [Component.t()],
          changed_component_ids: [Ecto.UUID.t()],
          dependency_observation: map()
        }

  defp environment(scope, opts) do
    case Keyword.fetch(opts, :environment) do
      {:ok, env} -> env
      :error -> WorkingCopies.environment(scope)
    end
  end

  @doc """
  Sync components from File records.

  ## Options
  - `:environment` — the filesystem environment to read, resolved from the
    active working copy when omitted.
  - `:base_dir` — accepted for backwards compatibility, ignored.
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
    env = environment(scope, opts)
    start = System.monotonic_time(:millisecond)

    # Only main's code says what exists — a feature copy's unpromoted module and
    # a stale worktree's deleted one are neither created nor kept on its word.
    live_files =
      scope
      |> query_files(changed_paths)
      |> live_only(scope.active_project_id)

    code =
      live_files
      |> Enum.map(&parse_impl_file(&1, env))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.module_name)

    do_sync(scope, code, live_files, is_list(changed_paths), start, removed_module_names, env)
  end

  @doc """
  Module names named by files that are gone — worth checking whether their
  component is now orphaned.

  Called by `FileSync` right after a reconcile removes rows, on the removed
  records themselves (their old `validation_errors` still carry the module
  name the scanner last stored). A file with no stored module name —
  `:test`/doc roles, or a row scanned before this was recorded — contributes
  nothing.
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

  defp do_sync(scope, code, live_files, incremental?, start, removed_module_names, env) do
    now = DateTime.utc_now()

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

    dependency_observation =
      sync_discovered_dependencies(scope, live_files, component_map, incremental?, env)

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
       changed_component_ids: changed_component_ids,
       dependency_observation: dependency_observation
     }}
  end

  # Components carry `implementation_file`, so creating or changing one moves
  # the graph. `FileSync`'s own announcement does not cover it: callers run
  # `FileSync.sync/2` and *then* this, so that announcement goes out before the
  # components exist. Nothing changed means nothing to say.
  # See knowledge/platform, "Component sync".
  defp announce_graph_change(_scope, []), do: :ok

  # The components that changed, from `compute_changed_ids/2`. Not `:project`:
  # `architecture_designed` is settled by the `files_synced` handler, and a
  # `:project` entity sent every vantage through a full project recompute.
  # Project-wide, because component *rows* are read by every checkout's
  # projection.
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

  @doc """
  Inspect dependency reconciliation without changing records. Evidence belongs to
  the scanned file, so a server without the checkout can report the same answer.
  Unreadable or unparsable files make removal unsafe; positive evidence remains
  usable. Authored edges remain authored even when code stops using them.
  """
  def dependency_report(%Scope{} = scope, opts \\ []) do
    env = environment(scope, opts)
    components = Components.list_components(scope)
    component_map = Map.new(components, &{&1.module_name, &1})
    files = scope |> query_files(nil) |> live_only(scope.active_project_id)
    observations = dependency_observations(scope, files, component_map, env)
    existing = Components.list_dependencies(scope)

    Map.merge(observations, %{
      additions:
        Enum.reject(observations.pairs, fn pair ->
          Enum.any?(existing, &({&1.source_component_id, &1.target_component_id} == pair))
        end),
      removals:
        Enum.filter(existing, fn edge ->
          removable_observation?(edge, observations) and edge.provenance == :discovered and
            stale_in_code?(edge, observations.pairs)
        end)
    })
  end

  # An incremental sync answers only for the modules its changed files declare:
  # their edges are reconciled, every other edge is left to the files that name it.
  defp sync_discovered_dependencies(_scope, [], _component_map, true, _env),
    do: %{status: :deferred, unavailable: [], unresolved: []}

  defp sync_discovered_dependencies(scope, files, component_map, incremental?, env) do
    observation = dependency_observations(scope, files, component_map, env)
    reconcile_discovered_dependencies(scope, observation, incremental?)

    if observation.unavailable != [] do
      Logger.warning(
        "[Files.ComponentSync] dependency removal deferred: " <>
          "#{length(observation.unavailable)} files have unavailable evidence"
      )
    end

    %{
      status: observation_status(observation),
      unavailable: observation.unavailable,
      unresolved: observation.unresolved
    }
  end

  defp dependency_observations(_scope, [], _component_map, _env),
    do: %{
      pairs: MapSet.new(),
      source_ids: MapSet.new(),
      evidence: [],
      unavailable: [%{reason: :no_source_snapshot}],
      unresolved: []
    }

  defp dependency_observations(_scope, files, component_map, env) do
    by_id = Map.new(Map.values(component_map), &{&1.id, &1})

    Enum.reduce(
      files,
      %{
        pairs: MapSet.new(),
        source_ids: MapSet.new(),
        evidence: [],
        unavailable: [],
        unresolved: []
      },
      fn file, acc ->
        case dependency_evidence(file, env) do
          %{"status" => "ok", "references" => references} = evidence ->
            pairs = Enum.flat_map(references, &evidence_pair(&1, component_map, by_id))
            sources = evidence_sources(evidence, component_map)

            location = %{
              path: file.path,
              working_copy_id: file.working_copy_id,
              source_hash: evidence["source_hash"]
            }

            %{
              acc
              | pairs: MapSet.union(acc.pairs, MapSet.new(pairs)),
                source_ids: MapSet.union(acc.source_ids, sources),
                evidence: [Map.put(location, :observation, evidence) | acc.evidence],
                unresolved:
                  Enum.map(evidence["unresolved"] || [], &Map.put(&1, "file", file.path)) ++
                    acc.unresolved
            }

          unavailable ->
            %{
              acc
              | unavailable: [
                  %{path: file.path, working_copy_id: file.working_copy_id, reason: unavailable}
                  | acc.unavailable
                ]
            }
        end
      end
    )
    |> Map.put(:uncertain_source_ids, MapSet.new())
    |> then(fn observation ->
      uncertain =
        observation.unresolved
        |> Enum.map(&Map.get(component_map, &1["source"]))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new(& &1.id)

      %{observation | uncertain_source_ids: uncertain}
    end)
  end

  defp observation_status(%{unavailable: [_ | _]}), do: :incomplete
  defp observation_status(%{unresolved: [_ | _]}), do: :partial
  defp observation_status(_), do: :observed

  defp removable_observation?(edge, observation) do
    observation.unavailable == [] and
      not MapSet.member?(
        Map.get(observation, :uncertain_source_ids, MapSet.new()),
        edge.source_component_id
      )
  end

  defp dependency_evidence(%File{validation_errors: errors, path: path}, environment) do
    case stored_component_data(errors) do
      %{"dependency_evidence" => %{"version" => 2} = evidence} ->
        evidence

      _ when is_nil(environment) ->
        %{error: :no_environment}

      _ ->
        case Environments.read_file(environment, path) do
          {:ok, source} -> DependencyEvidence.extract(source)
          {:error, reason} -> %{error: reason}
        end
    end
  end

  defp evidence_pair(
         %{"source" => source_name, "target" => target_name, "kind" => kind},
         component_map,
         by_id
       )
       when kind in ["call", "struct"] do
    with %Component{} = source <- Map.get(component_map, source_name),
         %Component{} = target <- Map.get(component_map, target_name),
         false <- source.id == target.id,
         false <- owning_context_id(source, by_id) == owning_context_id(target, by_id) do
      [{source.id, target.id}]
    else
      _ -> []
    end
  end

  defp evidence_pair(_reference, _component_map, _by_id), do: []

  defp evidence_sources(evidence, component_map) do
    for name <- evidence["modules"] || [],
        %Component{id: id} <- [Map.get(component_map, name)],
        into: MapSet.new(),
        do: id
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
  defp reconcile_discovered_dependencies(scope, observation, incremental?) do
    found = observation.pairs

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
    |> Enum.filter(
      &(answered_for?(&1, observation, incremental?) and removable_observation?(&1, observation) and
          stale_in_code?(&1, found))
    )
    |> Enum.each(&retire_discovered_dependency(scope, &1))
  end

  defp answered_for?(_dependency, _observation, false), do: true

  defp answered_for?(dependency, observation, true),
    do: MapSet.member?(observation.source_ids, dependency.source_component_id)

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
  # still holds. An authored component is the intended architecture whether
  # or not code exists yet, and an unmarked one is left for a person to
  # decide; only `delete_component` removes either.
  defp cleanup_removed(%Scope{active_project_id: project_id} = scope, existing) do
    claimed = live_claimed_names(project_id)

    existing
    |> Enum.filter(
      &(&1.provenance == :discovered and not MapSet.member?(claimed, &1.module_name))
    )
    |> prune_unreferenced(scope)
  end

  # `cleanup_removed/2`'s incremental counterpart: only the removed files'
  # module names are candidates. A removed file whose module never had a
  # component maps to nil and is no candidate.
  defp cleanup_orphaned(%Scope{active_project_id: project_id} = scope, module_names, existing_map) do
    claimed = live_claimed_names(project_id)

    module_names
    |> Enum.map(&Map.get(existing_map, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(
      &(&1.provenance == :discovered and not MapSet.member?(claimed, &1.module_name))
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
      select: f.module_name
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
      # Shared with `Files.read_model/1`, which indexes components by the same
      # paths; two copies drifted and wrote `nil` over the claim every scan.
      patterns =
        ConventionalPaths.for_component(%{module_name: module_name, type: component.type})

      File
      |> where(
        [f],
        f.project_id == ^project_id and f.path in ^patterns and is_nil(f.component_id)
      )
      |> Repo.update_all(set: [component_id: component.id])

      # Path patterns miss files Phoenix puts elsewhere (`MyAppWeb.CoreComponents`
      # under `components/`, `ErrorHTML` under `controllers/`), whose
      # `implementation_file` could then never be satisfied. So also claim by
      # the scanned `defmodule`. Still `is_nil(component_id)`: an owned file is
      # never stolen.
      File
      |> where(
        [f],
        f.project_id == ^project_id and f.role == :implementation and
          is_nil(f.component_id) and
          f.module_name == ^module_name
      )
      |> Repo.update_all(set: [component_id: component.id])
    end)
  end
end
