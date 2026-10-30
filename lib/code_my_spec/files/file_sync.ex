defmodule CodeMySpec.Files.FileSync do
  @moduledoc """
  Turns filesystem observations into File records.

  `CodeMySpec.Files.Scanner` does the half that needs the working copy — walk,
  classify, stat, fingerprint, validate. This module does the half that needs
  the database: linking entries to their owners, diffing them against what is
  already stored, upserting, and cleaning up rows and problems for files that
  are gone.

  The split is along what each half requires: scanning has to happen where the
  files are, projecting does not. The delegations at the bottom keep
  `FileSync.classify/1` and friends as entry points.
  """

  require Logger

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.ProjectKnowledgeReconciler
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.SpecBinding
  alias CodeMySpec.Problems
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  defp environment(scope, opts) do
    case Keyword.fetch(opts, :execution_context) do
      {:ok, env} -> env
      :error -> WorkingCopies.execution_context(scope)
    end
  end

  defp env_cwd(%{cwd: cwd}), do: cwd
  defp env_cwd(_), do: nil

  # Whitelist of roots walked on sync. Anything outside these trees is invisible
  # to FileSync — `deps/`, `_build/`, `node_modules/`, `priv/`, `assets/`, `.git/`
  # are never touched. Keep in sync with `classify/1`.

  @doc """
  Sync all trackable files from the filesystem into the DB.

  Returns `{:ok, %{upserted: count, removed: count, changed_paths: [path]}}`.

  Embeds nothing: embeddings are reconciled server-side (`Embeddings`).
  """
  @spec sync(Scope.t(), keyword()) :: {:ok, map()}
  def sync(%Scope{} = scope, opts \\ []) do
    env = environment(scope, opts)
    start = System.monotonic_time(:millisecond)

    # One read model for the whole pass.
    read_model = Files.read_model(scope)

    with {:ok, observations} <- observe(scope, env, read_model) do
      finish_sync(scope, observations, start, env)
    end
  end

  # An environment that cannot scan is not an empty working copy: the refusal
  # is carried out as `{:error, {:cannot_scan, reason}}` so no caller deletes
  # the projection on "could not look".
  defp observe(%Scope{} = scope, env, read_model) do
    case if(is_nil(env), do: {:error, :no_environment}, else: Scanner.observe(env, read_model)) do
      {:ok, observations} ->
        {:ok, observations}

      {:error, reason} ->
        # Level through `scan_refusal_level/1`: `sync_project` takes this branch
        # on purpose for every harness-held copy. Named by working copy, since
        # two checkouts share the project id.
        Logger.log(
          scan_refusal_level(reason),
          "[FileSync] #{working_copy(scope)}: refusing to sync — this environment " <>
            "cannot walk a working copy (#{inspect(reason)}). Nothing was scanned, so " <>
            "nothing is authoritative — the rows already recorded stand."
        )

        {:error, {:cannot_scan, reason}}
    end
  end

  defp finish_sync(scope, observations, start, env) do
    scan_ms = System.monotonic_time(:millisecond) - start

    %{
      upserted: upserted,
      removed: removed,
      changed_entries: changed_entries,
      removed_records: removed_records
    } = reconcile(scope, observations)

    file_entries = observations
    validate_ms = System.monotonic_time(:millisecond) - start - scan_ms

    maybe_reconcile_lockfile(scope, changed_entries, env)

    total_ms = System.monotonic_time(:millisecond) - start

    changed_paths = Enum.map(changed_entries, & &1.path)

    # Named by working copy, so two checkouts' lines are distinguishable.
    Logger.info(
      "[FileSync] #{working_copy(scope)}: #{length(file_entries)} files scanned in " <>
        "#{scan_ms}ms, validated in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{length(changed_paths)} changed, " <>
        "#{removed} removed, total #{total_ms}ms"
    )

    # Announced only when something changed; a quiet tree's scan would wake the
    # debounce for nothing. See `Requirements.GraphInputs`.
    if changed_paths != [] or upserted > 0 or removed > 0 do
      announce_graph_change(scope, changed_paths, upserted, removed)
    end

    {:ok,
     %{
       upserted: upserted,
       removed: removed,
       changed_paths: changed_paths,
       removed_module_names: ComponentSync.removed_module_names(removed_records),
       total_files: length(file_entries)
     }}
  end

  @doc """
  Turn observations into File rows.

  The interpretation half of sync. Takes what `Files.Scanner` saw — path, role,
  fingerprint, validity, owning component or story, and no file content — and
  reconciles it against what is stored: upserting what is there, removing what
  is not, and clearing problems belonging to files that no longer exist.

  Split out because observing has to happen where the files are; this needs
  only the database, so a harness that holds none sends its observations here.

  Takes the *whole* observation set rather than a delta: that is what tells a
  deletion from an omission.
  """
  @spec reconcile(Scope.t(), [map()]) :: map()
  def reconcile(%Scope{} = scope, observations) when is_list(observations) do
    CodeMySpec.Files.ComponentRenames.reconcile(scope, observations)

    # Ownership is decided here, against this server's live domain; whatever the
    # harness worked out is discarded. A harness's read model is fetched once at
    # join and goes stale (a sprite joins before any stories exist, so no spex
    # would ever link). The harness reports what a file *is*; the server decides
    # what it *belongs to*. See knowledge/platform, "File sync".
    observations =
      observations
      |> Scanner.resolve_owners(Files.read_model(scope))
      |> then(&SpecBinding.bind(scope, &1))

    # One statement, and it is both the write and the answer to what moved:
    # `upsert_files/2` updates a conflicting row only where a replaceable column
    # differs and returns exactly what it touched. A cold table returns every
    # row, so hydrating and reconciling are one operation.
    {upserted, changed} =
      case observations do
        [] -> {0, []}
        _ -> Files.upsert_files(scope, observations)
      end

    # Remove files no longer on disk + their orphaned problems (otherwise
    # stale failures from deleted files keep blocking stop hooks).
    current_paths = Enum.map(observations, & &1.path)
    {removed, removed_records} = Files.delete_removed(scope, current_paths)
    {:ok, orphaned} = Problems.clear_problems_for_missing_files(scope, current_paths)

    if orphaned > 0 do
      Logger.info("[FileSync] Cleared #{orphaned} orphaned problem(s) from deleted files")
    end

    # The harness's path: a scan arrives as a manifest and lands here, not
    # through `sync/2`, so this must announce too. Only when something moved;
    # a quiet tree sends one every few minutes.
    if changed != [] or upserted > 0 or removed > 0 do
      announce_graph_change(scope, changed, upserted, removed)
    end

    %{
      upserted: upserted,
      removed: removed,
      changed_entries: changed,
      removed_records: removed_records
    }
  end

  @doc """
  Reconcile a complete manifest in bounded, independently committed batches.

  Every upsert batch also projects its changed components in the same
  transaction. Deletions wait until every observed path has landed, then run
  in bounded batches with their problem cleanup and component projection. A
  timed-out batch can be retried without undoing earlier batches.
  """
  @reconcile_timeout_ms 60_000
  @reconcile_batch_size 250
  @reconcile_slow_ms 40_000

  @spec reconcile_and_project(Scope.t(), [map()]) :: %{
          upserted: non_neg_integer(),
          removed: non_neg_integer(),
          changed: non_neg_integer(),
          components: non_neg_integer() | :unchanged
        }
  def reconcile_and_project(%Scope{} = scope, observations) when is_list(observations) do
    started = System.monotonic_time(:millisecond)

    try do
      CodeMySpec.Files.ComponentRenames.reconcile(scope, observations)

      observations =
        observations
        |> Scanner.resolve_owners(Files.read_model(scope))
        |> then(&SpecBinding.bind(scope, &1))

      current_paths = Enum.map(observations, &Map.get(&1, :path))
      current_set = MapSet.new(current_paths)

      missing_paths =
        scope
        |> Files.list_files()
        |> Enum.reject(&MapSet.member?(current_set, &1.path))
        |> Enum.map(& &1.path)

      problem_paths = Problems.missing_problem_file_paths(scope, current_paths)

      initial = %{
        upserted: 0,
        removed: 0,
        changed: 0,
        components: :unchanged,
        moved: %{lockfile: false, knowledge: false},
        batches: 0,
        longest_batch_ms: 0
      }

      result =
        observations
        |> Enum.chunk_every(@reconcile_batch_size)
        |> Enum.reduce(initial, fn entries, acc ->
          {batch, ms} =
            transact_batch(scope, length(entries), fn ->
              {upserted, changed} = Files.upsert_files(scope, entries)
              summary = %{changed_entries: changed, removed: 0, removed_records: []}

              %{
                upserted: upserted,
                removed: 0,
                changed: length(changed),
                changed_entries: changed,
                removed_records: [],
                components: project_components(scope, summary)
              }
            end)

          announce_batch_change(scope, batch)
          merge_batch(acc, batch, ms)
        end)

      result =
        (missing_paths ++ problem_paths)
        |> Enum.uniq()
        |> Enum.chunk_every(@reconcile_batch_size)
        |> Enum.reduce(result, fn paths, acc ->
          {batch, ms} =
            transact_batch(scope, length(paths), fn ->
              {removed, removed_records} = Files.delete_removed_paths(scope, paths)
              {:ok, orphaned} = Problems.clear_problems_for_paths(scope, paths)

              if orphaned > 0 do
                Logger.info(
                  "[FileSync] Cleared #{orphaned} orphaned problem(s) from deleted files"
                )
              end

              summary = %{changed_entries: [], removed: removed, removed_records: removed_records}

              %{
                upserted: 0,
                removed: removed,
                changed: 0,
                changed_entries: [],
                removed_records: removed_records,
                components: project_components(scope, summary)
              }
            end)

          announce_batch_change(scope, batch)
          merge_batch(acc, batch, ms)
        end)

      log_duration(scope, observations, System.monotonic_time(:millisecond) - started, result)
      after_manifest(scope, result.moved)
      Map.drop(result, [:moved, :batches, :longest_batch_ms])
    rescue
      error ->
        log_failure(scope, observations, System.monotonic_time(:millisecond) - started, error)
        reraise error, __STACKTRACE__
    end
  end

  defp transact_batch(scope, count, operation, attempt \\ 1) do
    started = System.monotonic_time(:millisecond)

    try do
      {:ok, result} = Repo.transaction(operation, timeout: @reconcile_timeout_ms)
      ms = System.monotonic_time(:millisecond) - started

      :telemetry.execute([:code_my_spec, :file_sync, :batch], %{transaction_ms: ms}, %{
        count: count
      })

      Logger.info("[FileSync] committed batch of #{count} for #{working_copy(scope)} in #{ms}ms")
      {result, ms}
    rescue
      error ->
        if attempt == 1 and String.contains?(Exception.message(error), "timeout") do
          Logger.warning(
            "[FileSync] retrying timed-out batch of #{count} for #{working_copy(scope)}"
          )

          transact_batch(scope, count, operation, 2)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp announce_batch_change(scope, batch) do
    if batch.changed_entries != [] or batch.upserted > 0 or batch.removed > 0 do
      announce_graph_change(scope, batch.changed_entries, batch.upserted, batch.removed)
    end
  end

  defp merge_batch(acc, batch, ms) do
    moved = moved_roles(batch.changed_entries, batch.removed_records)

    %{
      acc
      | upserted: acc.upserted + batch.upserted,
        removed: acc.removed + batch.removed,
        changed: acc.changed + batch.changed,
        components: merge_component_count(acc.components, batch.components),
        moved: %{
          lockfile: acc.moved.lockfile or moved.lockfile,
          knowledge: acc.moved.knowledge or moved.knowledge
        },
        batches: acc.batches + 1,
        longest_batch_ms: max(acc.longest_batch_ms, ms)
    }
  end

  defp merge_component_count(:unchanged, next), do: next
  defp merge_component_count(count, :unchanged), do: count
  defp merge_component_count(count, next), do: count + next

  # The components, projected — unless no file moved, in which case they cannot
  # have. Incremental: only the components the changed files name, plus an
  # orphan check for what removed files named (`ComponentSync.removed_module_names/1`).
  # The full resync is for the explicit `/codemyspec:sync` and `sync_project`
  # surfaces; on every manifest it cost seconds and a pooled connection.
  # Keyed on `removed` too: a deletion changes the projection without changing
  # any surviving row. `:unchanged` rather than a count, because no number here
  # would be true.
  defp project_components(_scope, %{changed_entries: [], removed: 0}), do: :unchanged

  # No execution_context: the manifest is the harness's own report, and reading a file
  # back from inside its channel asks the process that is waiting on this one.
  defp project_components(scope, summary) do
    changed_paths = Enum.map(summary.changed_entries, & &1.path)
    removed_module_names = ComponentSync.removed_module_names(summary.removed_records)

    {:ok, components} =
      ComponentSync.sync_from_files(scope,
        execution_context: nil,
        changed_paths: changed_paths,
        removed_module_names: removed_module_names
      )

    length(components.all_components)
  end

  # The scanned count is every file on a quiet tree; this says how many moved.
  # Reads `:changed`, which `reconcile_and_project/2` already reduced to a count.
  defp moved_summary(%{upserted: upserted, removed: removed, changed: changed}) do
    " — #{changed} changed, #{upserted} upserted, #{removed} removed"
  end

  defp moved_summary(_result), do: ""

  # The one line that ties a sync to the recompute it causes: without it a
  # recompute gets attributed to the nearest preceding event, which on a busy
  # machine is often wrong.
  defp announce_graph_change(scope, changed_paths, upserted, removed) do
    obs = GraphInputs.observation_id()

    Logger.info(
      "[FileSync] announcing a graph change for #{working_copy(scope)} — " <>
        "#{length(changed_paths)} changed, #{upserted} upserted, #{removed} removed",
      obs: obs
    )

    # Recorded here rather than through `GraphInputs.announce/4`, so the log
    # line above and the mark share one observation id. The event settles what
    # persona files move and wakes this copy's agents; a copy's file verdicts
    # are read from its overlay, so it names no entity to recompute.
    Invalidations.record_event(
      scope.active_project_id,
      "FileSync",
      "files_synced",
      %{},
      [],
      obs,
      scope.active_working_copy_id
    )

    GraphInputs.changed(scope, obs)
  end

  # Every reconcile logs its duration, not only slow ones, so a trend is visible;
  # a timeout otherwise surfaces only as a closed channel and a rejoin loop.
  # See knowledge/platform, "File sync".
  defp log_duration(scope, observations, ms, result) do
    count = length(observations)
    copy = working_copy(scope)
    moved = moved_summary(result)

    if ms >= @reconcile_slow_ms do
      Logger.warning(
        "[FileSync] reconciled #{count} observations for #{copy} in #{ms}ms — within " <>
          "across #{result.batches} batches; longest batch #{result.longest_batch_ms}ms. " <>
          "Each batch has a #{@reconcile_timeout_ms}ms transaction limit. See 5be796f2."
      )
    else
      Logger.info("[FileSync] reconciled #{count} observations for #{copy} in #{ms}ms#{moved}")
    end
  end

  # Name the reconcile on its way past, then reraise with the original
  # stacktrace. `Repo.transaction/2` raises on timeout with the connection's
  # vocabulary only ("tcp recv: timeout"), and a few frames later it is a
  # closed channel; this is the line that says it was a reconcile.
  defp log_failure(scope, observations, ms, error) do
    Logger.error(
      "[FileSync] reconcile of #{length(observations)} observations for " <>
        "#{working_copy(scope)} FAILED after #{ms}ms (timeout is " <>
        "#{@reconcile_timeout_ms}ms per batch): #{Exception.message(error)}. " <>
        "Earlier batches remain committed; the failed batch can be retried from " <>
        "the same manifest. See 5be796f2."
    )
  end

  # Which checkout a line is about: `cwd` when the scope has it, the harness id
  # otherwise (a server-side scope has no path).
  defp working_copy(%Scope{cwd: cwd}) when is_binary(cwd), do: cwd
  defp working_copy(%Scope{active_working_copy_id: id}) when is_binary(id), do: "harness #{id}"
  defp working_copy(_scope), do: "an unnamed working copy"

  # -- Lockfile reconcile --
  #
  # The manifest carries no file content, so a changed `:lockfile` entry is
  # only a signal to go read it. Cheap on every sync, and safe from the
  # periodic sweep with no signal, because `reconcile_lockfile/2` re-derives
  # "did it change" from stored state.
  defp maybe_reconcile_lockfile(scope, changed_entries, env) do
    if Enum.any?(changed_entries, &(&1.role == :lockfile)) do
      reconcile_lockfile(scope, execution_context: env)
    end

    :ok
  end

  @doc """
  Re-derive a project's dependency set from its main copy's `mix.lock`, if
  the lock has moved since the last time this ran.

  One decision procedure for two callers: `maybe_reconcile_lockfile/3`
  triggers this when a manifest shows `mix.lock` changed, and
  `CodeMySpec.Files.LockfileSweep` calls it on a timer across every project.
  Neither trusts its trigger — this compares the project's stored
  `mix_lock_fingerprint` with the `files` row's fingerprint itself — so the
  sweep is a backstop: a reconcile that failed mid-read leaves the stored
  fingerprint stale and the next tick tries again.
  """
  @spec reconcile_lockfile(Scope.t()) :: :ok
  def reconcile_lockfile(scope, opts \\ [])

  def reconcile_lockfile(%Scope{active_project: %Project{}} = scope, opts) do
    env = environment(scope, opts)

    if main_copy?(scope) do
      do_reconcile_lockfile(scope, env)
    else
      :ok
    end
  end

  def reconcile_lockfile(%Scope{}, _opts), do: :ok

  defp main_copy?(%Scope{active_working_copy_id: id}) when not is_binary(id), do: false

  defp main_copy?(%Scope{active_working_copy_id: id} = scope) do
    match?(%WorkingCopy{id: ^id}, WorkingCopies.main(scope))
  end

  defp do_reconcile_lockfile(%Scope{active_project: project} = scope, env) do
    case Files.get_by_path(scope, "mix.lock") do
      %FileRecord{fingerprint: fingerprint}
      when is_binary(fingerprint) and fingerprint != project.mix_lock_fingerprint ->
        fetch_and_record_lockfile(scope, project, fingerprint, env)

      _ ->
        :ok
    end
  end

  defp fetch_and_record_lockfile(_scope, _project, _fingerprint, nil), do: :ok

  defp fetch_and_record_lockfile(scope, project, fingerprint, env) do
    with {:ok, content} <- ExecutionContexts.read_file(env, "mix.lock"),
         {:ok, _} <- Dependencies.record_lockfile(scope, content) do
      Projects.update_project(scope, project, %{mix_lock_fingerprint: fingerprint})
      :ok
    else
      {:error, reason} ->
        Logger.info(
          "[FileSync] #{working_copy(scope)}: lockfile reconcile deferred (#{inspect(reason)})"
        )

        :ok
    end
  end

  # -- Project knowledge reconcile --

  # The manifest-fed roles whose content the server reads back over the
  # harness: `mix.lock` and project knowledge.
  defp moved_roles(changed_entries, removed_records) do
    roles = MapSet.new(changed_entries ++ removed_records, &Map.get(&1, :role))
    %{lockfile: :lockfile in roles, knowledge: :project_knowledge in roles}
  end

  # After the transaction commits, and off the caller: the manifest's caller
  # may be the channel itself (inline mode), and a read from there self-calls.
  defp after_manifest(_scope, %{lockfile: false, knowledge: false}), do: :ok

  defp after_manifest(scope, moved) do
    if Application.get_env(:code_my_spec, :analysis_mode) == :inline do
      reconcile_moved(scope, moved)
    else
      {:ok, _pid} =
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          reconcile_moved(scope, moved)
        end)

      :ok
    end
  end

  defp reconcile_moved(scope, moved) do
    if moved.lockfile, do: reconcile_lockfile(scope)
    if moved.knowledge, do: reconcile_project_knowledge(scope)
    :ok
  end

  @doc """
  Bring the project's `project_knowledge` embeddings in line with its main
  copy's `project_knowledge` file rows, reading changed content over the
  copy's harness.

  Called by a manifest that moved a knowledge row and by `LockfileSweep`.
  A no-op off the main copy and off `PgVectorBackend`. An unreachable
  harness leaves changed files pending for the next pass; it never deletes
  their rows.
  """
  @spec reconcile_project_knowledge(Scope.t()) :: :ok
  def reconcile_project_knowledge(scope, opts \\ [])

  def reconcile_project_knowledge(%Scope{active_project: %Project{} = project} = scope, opts) do
    env = environment(scope, opts)

    if Embeddings.server_reconciled?() and main_copy?(scope) do
      do_reconcile_project_knowledge(scope, project, env)
    else
      :ok
    end
  end

  def reconcile_project_knowledge(%Scope{}, _opts), do: :ok

  defp do_reconcile_project_knowledge(_scope, _project, nil), do: :ok

  defp do_reconcile_project_knowledge(scope, project, env) do
    desired =
      scope
      |> Files.list_files_with_role(:project_knowledge)
      |> Map.new(&{&1.path, &1.fingerprint})

    case ProjectKnowledgeReconciler.reconcile(
           project.id,
           desired,
           &ExecutionContexts.read_file(env, &1)
         ) do
      {:ok, _summary} ->
        :ok

      {:error, {:deferred, reason}, summary} ->
        Logger.info(
          "[FileSync] #{working_copy(scope)}: project knowledge reconcile deferred after " <>
            "#{summary.embedded} file(s) (#{inspect(reason, limit: 5)})"
        )

        :ok
    end
  end

  @doc """
  Sync only changed files from the filesystem into the DB.

  Compares filesystem mtime against existing DB records and only processes
  files that are new or have a newer mtime. Still removes files no longer on disk.

  Returns `{:ok, %{upserted: count, removed: count, changed_paths: [path], total_files: count}}`.
  """
  @spec sync_changed(Scope.t(), keyword()) :: {:ok, map()}
  def sync_changed(%Scope{} = scope, opts \\ []) do
    env = environment(scope, opts)
    start = System.monotonic_time(:millisecond)

    with {:ok, stream} <- walk(scope, env) do
      finish_sync_changed(scope, env, Enum.to_list(stream), start)
    end
  end

  # The stop hook's scan. A refusal returns `{:error, {:cannot_scan, _}}`, never
  # an empty stream: an empty walk would delete every row.
  defp walk(%Scope{} = scope, env) do
    case if(is_nil(env), do: {:error, :no_environment}, else: Scanner.stream_files(env)) do
      {:ok, stream} ->
        {:ok, stream}

      {:error, reason} ->
        Logger.log(
          scan_refusal_level(reason),
          "[FileSync] #{working_copy(scope)}: refusing to sync changed files — this " <>
            "environment cannot walk a working copy (#{inspect(reason)}). Nothing was " <>
            "scanned, so nothing is authoritative and the recorded rows stand."
        )

        {:error, {:cannot_scan, reason}}
    end
  end

  # The refusal is identical either way; only the log level changes.
  # `:not_supported_on_harness` is a property of the environment — a working
  # copy on another machine has no disk here — and fires on every stop hook for
  # a harness-backed copy, so it logs at `:info`. Any other refusal is an event
  # and logs at `:error`. Both `walk/2` and `observe/3` use this.
  #
  # Public so the decision can be asserted directly: the suite pins Logger at
  # `:warning`, so an `:info` line is unobservable through `CaptureLog`.
  @doc "The log level for a scan refusal — `:info` for a routine one, `:error` otherwise."
  def scan_refusal_level(:not_supported_on_harness), do: :info
  def scan_refusal_level(_reason), do: :error

  defp finish_sync_changed(%Scope{} = scope, env, file_entries, start) do
    scan_ms = System.monotonic_time(:millisecond) - start

    # Two columns, not the whole table: only the mtime pre-filter needs it.
    existing_mtime_map = Files.mtimes_by_path(scope)

    # mtime is the cheap pre-filter: only new or newer files are opened and
    # fingerprinted. Whether content moved is the upsert's to decide.
    mtime_changed_entries =
      Enum.filter(file_entries, fn entry ->
        case Map.get(existing_mtime_map, entry.path) do
          nil -> true
          db_mtime -> DateTime.compare(entry.mtime, db_mtime) == :gt
        end
      end)

    {upserted, fingerprint_changed_entries} =
      case mtime_changed_entries do
        [] ->
          {0, []}

        _ ->
          read_model = Files.read_model(scope)

          entries_with_owners = Scanner.resolve_owners(mtime_changed_entries, read_model)
          entries_with_fingerprints = Scanner.fingerprint_entries(env, entries_with_owners)

          component_by_id = read_model.component_by_id
          strict? = read_model.strict?

          validated_entries =
            Enum.map(
              entries_with_fingerprints,
              &Scanner.validate_entry(&1, env, component_by_id, strict?)
            )

          # The upsert says what moved: the rows that come back are the ones
          # whose content, role, ownership or validity actually differs.
          Files.upsert_files(scope, SpecBinding.bind(scope, validated_entries))
      end

    # `changed_paths` reflects files the agent touched this turn (mtime-bumped).
    # Validation drives analyzer selection from this set. The fingerprint
    # diff gates the lockfile reconcile and the specs_ready clear below.
    changed_paths = Enum.map(mtime_changed_entries, & &1.path)

    validate_ms = System.monotonic_time(:millisecond) - start - scan_ms

    # Remove files no longer on disk + their orphaned problems (otherwise
    # stale failures from deleted files keep blocking stop hooks).
    current_paths = Enum.map(file_entries, & &1.path)
    {removed, removed_records} = Files.delete_removed(scope, current_paths)
    {:ok, orphaned} = Problems.clear_problems_for_missing_files(scope, current_paths)

    if orphaned > 0 do
      Logger.info("[FileSync] Cleared #{orphaned} orphaned problem(s) from deleted files")
    end

    maybe_reconcile_lockfile(scope, fingerprint_changed_entries, env)

    clear_specs_ready_for_rewritten_specs(scope, fingerprint_changed_entries, removed_records)

    total_ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[FileSync] #{working_copy(scope)}: #{length(file_entries)} files scanned in " <>
        "#{scan_ms}ms, #{length(changed_paths)} changed, validated in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{removed} removed, total #{total_ms}ms"
    )

    {:ok,
     %{
       upserted: upserted,
       removed: removed,
       changed_paths: changed_paths,
       removed_module_names: ComponentSync.removed_module_names(removed_records),
       total_files: length(file_entries)
     }}
  end

  # Rewriting a story's BDD specs changes the contract, so the story has to
  # earn specs-ready again. Keyed on the *fingerprint*-changed set: a
  # byte-identical rewrite is not a contract change. Deletions count too.
  defp clear_specs_ready_for_rewritten_specs(scope, changed_entries, removed_records) do
    story_ids =
      (changed_entries ++ removed_records)
      |> Enum.filter(&(Map.get(&1, :role) == :bdd_spec))
      |> Enum.map(&Map.get(&1, :story_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for story_id <- story_ids,
        story = Stories.get_story(scope, story_id),
        story != nil,
        story.specs_ready == true do
      {:ok, _story} = Stories.set_specs_ready(scope, story, false)

      Logger.info("[FileSync] Story #{story_id} BDD specs rewritten — cleared specs_ready")
    end

    :ok
  end

  @doc """
  Sync a single file path from the filesystem into the DB.

  Takes an absolute path, classifies it, validates if needed,
  and upserts or deletes the file record.

  Returns `{:ok, %{changed_path: path | nil}}` where path is nil if
  the file was unrecognized or ignored.
  """
  @spec sync_path(Scope.t(), String.t(), keyword()) :: {:ok, map()}
  def sync_path(%Scope{} = scope, abs_path, opts \\ []) do
    env = environment(scope, opts)
    base_dir = Keyword.get(opts, :base_dir, env_cwd(env) || ".")
    rel_path = Path.relative_to(abs_path, base_dir)

    cond do
      is_nil(env) ->
        {:error, {:cannot_scan, :no_environment}}

      Scanner.ignored_path?(rel_path) ->
        {:ok, %{changed_path: nil}}

      classified = classify(rel_path) ->
        {path, role} = classified
        sync_classified_path(scope, env, path, role)

      true ->
        {:ok, %{changed_path: nil}}
    end
  end

  defp sync_classified_path(scope, env, path, role) do
    existing = Files.get_by_path(scope, path)

    case stat_file(env, path, role) do
      nil ->
        Files.delete_by_paths(scope, [path])
        removed_records = if existing, do: [existing], else: []
        clear_specs_ready_for_rewritten_specs(scope, [], removed_records)
        announce_watched_change(scope, existing != nil)
        {:ok, %{changed_path: path}}

      entry ->
        # Upsert metadata (role, owners, valid, fingerprint) but NOT mtime, so
        # sync_changed still picks the file up in the stop hook pass. The
        # fingerprint updates eagerly so out-of-band consumers react in real
        # time. Owner resolution and component-aware validation run only for
        # owner-bearing roles; doc-corpus writes would otherwise each query
        # every component.
        entry =
          cond do
            owner_bearing_role?(role) ->
              read_model = Files.read_model(scope)
              [entry] = Scanner.resolve_owners([entry], read_model)
              [entry] = Scanner.fingerprint_entries(env, [entry])

              entry =
                Scanner.validate_entry(entry, env, read_model.component_by_id, read_model.strict?)

              [entry] = SpecBinding.bind(scope, [entry])
              entry

            setup_validated_role?(role) ->
              # Setup-config-style roles have no owner but need
              # `validate_entry` to populate `validation_errors`, which the
              # Setup.* `check/1` functions read.
              [entry] = Scanner.fingerprint_entries(env, [entry])

              component_by_id =
                if role == :architecture, do: Files.read_model(scope).component_by_id, else: %{}

              Scanner.validate_entry(entry, env, component_by_id, false)

            true ->
              [entry] = Scanner.fingerprint_entries(env, [entry])

              entry
              |> Map.put(:component_id, nil)
              |> Map.put(:story_id, nil)
              |> Map.put(:valid, true)
              |> Map.put(:validation_errors, nil)
          end

        fingerprint_changed_entries =
          if fingerprint_changed?(entry, existing), do: [entry], else: []

        Files.upsert_file_metadata(scope, entry)

        # Here, not only in the stop hook's pass: this path updates the
        # fingerprint eagerly, so by `finish_sync_changed/4` the stored
        # fingerprint already matches and that pass's clear never sees the
        # rewrite. The watcher is what an agent's spec rewrite fires.
        # See knowledge/platform, "File sync".
        clear_specs_ready_for_rewritten_specs(scope, fingerprint_changed_entries, [])

        announce_watched_change(scope, fingerprint_changed_entries != [])
        {:ok, %{changed_path: path}}
    end
  end

  # The watcher's path announces too: `sync_path/3` is what a file event fires,
  # and a fingerprint is a graph input. Without it, readers had to rescan to
  # learn what the watcher knew. Only on a real change — a moved fingerprint or
  # a removed file; a save with no edit announces nothing.
  defp announce_watched_change(_scope, false), do: :ok

  defp announce_watched_change(scope, true),
    do: GraphInputs.announce(scope, "FileSync.watched", [], :this_checkout)

  # Roles with a component or story owner. Others (project_knowledge, rule,
  # architecture, …) are standalone documents with no owner to resolve.
  defp owner_bearing_role?(role)
       when role in [:implementation, :test, :spec, :bdd_spec, :qa_brief, :qa_result, :review],
       do: true

  defp owner_bearing_role?(_), do: false

  # Roles with no owner that still need `validate_entry` to populate
  # `validation_errors`: the Setup.* `check/1` functions read those errors,
  # and without validation `Setup.Context.error/4` returns the missing_msg
  # fallback forever. This is every non-owner-bearing role
  # `Scanner.validate_entry/4` has a clause for; one missing here falls to the
  # branch that stamps `valid: true` unread, so a single-path write and a full
  # scan would disagree.
  defp setup_validated_role?(role)
       when role in [
              :claude_md,
              :mix_exs,
              :credo_exs,
              :setup_config,
              :test_support,
              :qa_plan,
              :persona_summary,
              :persona_sources,
              :architecture
            ],
       do: true

  defp setup_validated_role?(_), do: false

  defp fingerprint_changed?(_entry, nil), do: true

  defp fingerprint_changed?(entry, %{fingerprint: existing_fingerprint}) do
    Map.get(entry, :fingerprint) != existing_fingerprint
  end

  # Reads each entry's content and stamps a SHA-256 fingerprint on the File
  # row. mtime is the cheap pre-filter that tells sync to look at a file;
  # fingerprint is what out-of-band consumers (analyzers, embedders) gate on.
  @doc false

  # -- Scanning (delegated) --
  #
  # Implemented in `CodeMySpec.Files.Scanner`; kept here as entry points.

  defdelegate classify(path), to: Scanner
  defdelegate stat_file(env, path, role), to: Scanner
  defdelegate stream_files(env), to: Scanner
  defdelegate fingerprint_entries(env, entries), to: Scanner
  defdelegate validate_entry(entry, env, component_by_id, strict?), to: Scanner

  @doc "Convenience over `validate_entry/4` defaulting `strict?` to true."
  def validate_entry(entry, env, component_by_id),
    do: Scanner.validate_entry(entry, env, component_by_id, true)

  @doc "Convenience over `Scanner.resolve_owners/2` that builds the read model from `scope`."
  def resolve_owners(scope, entries),
    do: Scanner.resolve_owners(entries, Files.read_model(scope))
end
