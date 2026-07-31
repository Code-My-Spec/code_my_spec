defmodule CodeMySpec.Files.FileSync do
  @moduledoc """
  Turns filesystem observations into File records.

  `CodeMySpec.Files.Scanner` does the half that needs the working copy — walk,
  classify, stat, fingerprint, validate. This module does the half that needs
  the database: linking entries to their owners, diffing them against what is
  already stored, upserting, and cleaning up rows and problems for files that
  are gone.

  The split is along what each half requires, not along what is convenient:
  scanning has to happen where the files are, projecting does not. Delegations
  below keep the pre-split call sites working.
  """

  require Logger

  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Paths
  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope

  # Files whose role makes them part of the project doc embedding corpus.
  # Updates and deletions for these flow into the Embeddings backend on
  # every sync so semantic_search stays current with disk.
  #
  # Most roles map 1:1 to a fixed source string. `:hex_doc` is the
  # exception — its source is `"hexdocs:<package>"`, derived from the
  # path segment under `Paths.hex_docs_dir/0`. Resolution happens in
  # `embeddable_source/2`.
  #
  # Framework knowledge (the `"knowledge"` source) does NOT live in
  # the working tree; `Embeddings.sync_framework_knowledge/1` reads
  # it directly from `priv/knowledge/`. So no role here points at
  # `"knowledge"` — that's a corpus the file walker never touches.
  @fixed_role_sources %{
    spec: "spec",
    rule: "rules",
    project_knowledge: "project_knowledge"
  }

  defp embeddable_source(:hex_doc, path) do
    case String.replace_prefix(path, Paths.hex_docs_dir() <> "/", "") do
      ^path -> nil
      rest -> "hexdocs:" <> (rest |> String.split("/") |> hd())
    end
  end

  defp embeddable_source(role, _path), do: Map.get(@fixed_role_sources, role)

  # Whitelist of roots walked on sync. Anything outside these trees is invisible
  # to FileSync — `deps/`, `_build/`, `node_modules/`, `priv/`, `assets/`, `.git/`
  # are never touched. Keep in sync with `classify/1`.

  @doc """
  Sync all trackable files from the filesystem into the DB.

  Returns `{:ok, %{upserted: count, removed: count, changed_paths: [path]}}`.

  Options:

    * `:embed` — when `false`, skips the embedding hooks (framework knowledge
      sync, hex doc projection, and per-file embedding upserts). Use for
      fast UI refreshes where staleness of semantic_search is acceptable.
      Defaults to `true`.
  """
  @spec sync(Scope.t(), keyword()) :: {:ok, map()}
  def sync(%Scope{environment: env} = scope, opts \\ []) do
    embed? = Keyword.get(opts, :embed, true)
    start = System.monotonic_time(:millisecond)

    if embed? do
      # Sync the bundled framework knowledge corpus directly from
      # `priv/knowledge/` into the embedding store. No working-tree
      # copy — the embedding backend's content-hash dedup keeps no-op
      # syncs cheap.
      Embeddings.sync_framework_knowledge(scope)

      # Project dependency docs from `deps/<pkg>` source into the working
      # tree before walking files. Newly-installed/updated/removed
      # packages produce markdown changes the walker then catches via
      # fingerprint diff, routing them through the same embedding hook
      # every other doc role uses.
      HexDocProjector.project(scope)
    end

    # One read model for the whole pass. The pre-split code queried components
    # twice — once for ownership, once for validation — and the config flag
    # separately; scanning now states what it needs and gets it once.
    read_model = Files.read_model(scope)

    observations = Scanner.observe(env, read_model)

    scan_ms = System.monotonic_time(:millisecond) - start

    %{
      upserted: upserted,
      removed: removed,
      changed_entries: changed_entries,
      removed_records: removed_records
    } = reconcile(scope, observations)

    file_entries = observations
    validate_ms = System.monotonic_time(:millisecond) - start - scan_ms

    if embed?, do: sync_embeddings(scope, env, changed_entries, removed_records)

    total_ms = System.monotonic_time(:millisecond) - start

    changed_paths = Enum.map(changed_entries, & &1.path)

    Logger.info(
      "[FileSync] #{length(file_entries)} files scanned in #{scan_ms}ms, " <>
        "validated in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{length(changed_paths)} changed, " <>
        "#{removed} removed, total #{total_ms}ms"
    )

    {:ok,
     %{
       upserted: upserted,
       removed: removed,
       changed_paths: changed_paths,
       total_files: length(file_entries)
     }}
  end

  @doc """
  Turn observations into File rows.

  The interpretation half of sync. Takes what `Files.Scanner` saw — path, role,
  fingerprint, validity, owning component or story, and no file content — and
  reconciles it against what is stored: upserting what is there, removing what
  is not, and clearing problems belonging to files that no longer exist.

  Split out because the two halves need different machines. Observing has to
  happen where the files are; this needs only the database, and a harness that
  holds none can send its observations here instead of writing rows itself.

  Note that it takes the *whole* observation set rather than a delta. That is
  what lets it tell a deletion from an omission — a stream of per-file updates
  cannot, and would silently retain rows for files that had gone.
  """
  @spec reconcile(Scope.t(), [map()]) :: map()
  def reconcile(%Scope{} = scope, observations) when is_list(observations) do
    # Snapshot existing rows up front so we can compute fingerprint diffs
    # (real "changed paths") and capture the role of files that are about
    # to be removed (so embedding cleanup knows the source/path tuple).
    existing_records = Files.list_files(scope)
    existing_by_path = Map.new(existing_records, &{&1.path, &1})

    {upserted, changed} =
      case observations do
        [] ->
          {0, []}

        _ ->
          changed = changed_entries(observations, existing_by_path)
          {count, _} = Files.upsert_files(scope, observations)
          {count, changed}
      end

    # Remove files no longer on disk + their orphaned problems (otherwise
    # stale failures from deleted files keep blocking stop hooks).
    current_paths = Enum.map(observations, & &1.path)
    current_path_set = MapSet.new(current_paths)

    removed_records =
      Enum.reject(existing_records, &MapSet.member?(current_path_set, &1.path))

    {removed, _} = Files.delete_removed(scope, current_paths)
    {:ok, orphaned} = Problems.clear_problems_for_missing_files(scope, current_paths)

    if orphaned > 0 do
      Logger.info("[FileSync] Cleared #{orphaned} orphaned problem(s) from deleted files")
    end

    %{
      upserted: upserted,
      removed: removed,
      changed_entries: changed,
      removed_records: removed_records
    }
  end

  # Entries whose fingerprint differs from the existing DB row (or that
  # have no row yet) — i.e., files whose content actually changed since
  # the last sync. Used to drive embedding work and to populate the
  # user-visible "Changed files" count on the /files page.
  defp changed_entries(entries, existing_by_path) do
    Enum.filter(entries, fn entry ->
      case Map.get(existing_by_path, entry.path) do
        nil -> true
        record -> Map.get(entry, :fingerprint) != record.fingerprint
      end
    end)
  end

  @doc """
  Run the embedding side of sync against the currently-tracked corpus,
  without re-walking the filesystem or upserting File records.

  Three steps:

    * `Embeddings.sync_framework_knowledge/1` — push bundled `priv/knowledge/`
      into the embedding store.
    * `HexDocProjector.project/1` — project hex docs from `deps/` source
      into the working tree.
    * Embed every currently-tracked file whose role belongs to the doc corpus.

  No-ops gracefully when the embedding backend is unavailable. The
  backend's content-hash dedup keeps this cheap on repeat calls.
  """
  @spec embed_only(Scope.t()) :: {:ok, map()}
  def embed_only(%Scope{environment: env} = scope) do
    start = System.monotonic_time(:millisecond)

    Embeddings.sync_framework_knowledge(scope)
    HexDocProjector.project(scope)

    embeddable_records =
      scope
      |> Files.list_files()
      |> Enum.filter(&embeddable_source(&1.role, &1.path))

    if Embeddings.available?() do
      Enum.each(embeddable_records, &embed_entry(scope, env, &1))
    end

    elapsed = System.monotonic_time(:millisecond) - start

    Logger.info("[FileSync] embed_only: #{length(embeddable_records)} files in #{elapsed}ms")

    {:ok, %{embedded: length(embeddable_records), elapsed_ms: elapsed}}
  end

  # Push doc-corpus changes (spec / rule / knowledge / project_knowledge)
  # into the configured Embeddings backend. New and modified files are
  # re-embedded; removed files have their embeddings dropped. No-ops
  # gracefully when the backend is unavailable (Phoenix dev server).
  defp sync_embeddings(_scope, _env, [], []), do: :ok

  defp sync_embeddings(scope, env, changed_entries, removed_records) do
    if Embeddings.available?() do
      Enum.each(changed_entries, &embed_entry(scope, env, &1))
      Enum.each(removed_records, &delete_embeddings_for(scope, &1))
    end

    :ok
  end

  defp embed_entry(scope, env, entry) do
    case embeddable_source(entry.role, entry.path) do
      nil -> :ok
      source -> embed_changed_entry(scope, env, source, entry.path)
    end
  end

  defp delete_embeddings_for(scope, record) do
    case embeddable_source(record.role, record.path) do
      nil -> :ok
      source -> do_delete_embeddings(scope, source, record.path)
    end
  end

  defp do_delete_embeddings(scope, source, path) do
    case Embeddings.delete_path(scope, source, path) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[FileSync] delete_path failed for #{source}/#{path}: #{inspect(reason)}")
    end
  end

  defp embed_changed_entry(scope, env, source, path) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        case Embeddings.embed_file(scope, source, path, content) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[FileSync] embed_file failed for #{source}/#{path}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning("[FileSync] read_file failed for #{path}: #{inspect(reason)}")
    end
  end

  @doc """
  Sync only changed files from the filesystem into the DB.

  Compares filesystem mtime against existing DB records and only processes
  files that are new or have a newer mtime. Still removes files no longer on disk.

  Returns `{:ok, %{upserted: count, removed: count, changed_paths: [path], total_files: count}}`.
  """
  @spec sync_changed(Scope.t(), keyword()) :: {:ok, map()}
  def sync_changed(%Scope{environment: env} = scope, _opts \\ []) do
    start = System.monotonic_time(:millisecond)

    # Note: framework_knowledge sync and hex doc projection are NOT
    # pre-passes here. Both walk every file/dep-source file and would
    # re-embed (or re-render markdown) on every stop hook even when
    # nothing changed — the chunk-hash dedup downstream prevents
    # inference but the surrounding DB queries and source-parsing work
    # still runs. Stop hooks fire often; we don't want that overhead each
    # time. Triggers that actually need them:
    #   * Manual full sync — `FileSync.sync/2` (e.g. /files page button)
    #   * App boot — `FileWatcherServer.handle_continue/2`
    #   * Dep change — `FileWatcherServer` mix.lock-poll handler runs
    #     `HexDocProjector.project/1` after a debounce settle window
    file_entries =
      env
      |> stream_files()
      |> Enum.to_list()

    scan_ms = System.monotonic_time(:millisecond) - start

    # Snapshot existing rows up front so the embedding hook can compute
    # fingerprint diffs and capture roles for files about to be removed.
    existing_records = Files.list_files(scope)
    existing_by_path = Map.new(existing_records, &{&1.path, &1})
    existing_mtime_map = Map.new(existing_records, &{&1.path, &1.mtime})

    # mtime is the cheap pre-filter: only process files that are new or
    # have a newer mtime. Fingerprint diff still gates embedding work,
    # so an mtime bump without a content change is a no-op downstream.
    mtime_changed_entries =
      Enum.filter(file_entries, fn entry ->
        case Map.get(existing_mtime_map, entry.path) do
          nil -> true
          db_mtime -> DateTime.compare(entry.mtime, db_mtime) == :gt
        end
      end)

    {upserted, embedding_changed_entries} =
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

          embedding_changed = changed_entries(validated_entries, existing_by_path)

          {count, _} = Files.upsert_files(scope, validated_entries)
          {count, embedding_changed}
      end

    # `changed_paths` reflects files the agent touched this turn (mtime-bumped).
    # Validation drives analyzer selection and `:block_changed` scope from this
    # set — a rewrite of byte-identical impl content still needs the runner
    # analyzers to pick up the corresponding test failures. Fingerprint diff
    # gates embedding work only; that's why `embedding_changed_entries` stays
    # internal to `sync_embeddings/4` below.
    changed_paths = Enum.map(mtime_changed_entries, & &1.path)

    validate_ms = System.monotonic_time(:millisecond) - start - scan_ms

    # Remove files no longer on disk + their orphaned problems (otherwise
    # stale failures from deleted files keep blocking stop hooks).
    current_paths = Enum.map(file_entries, & &1.path)
    current_path_set = MapSet.new(current_paths)

    removed_records =
      Enum.reject(existing_records, &MapSet.member?(current_path_set, &1.path))

    {removed, _} = Files.delete_removed(scope, current_paths)
    {:ok, orphaned} = Problems.clear_problems_for_missing_files(scope, current_paths)

    if orphaned > 0 do
      Logger.info("[FileSync] Cleared #{orphaned} orphaned problem(s) from deleted files")
    end

    sync_embeddings(scope, env, embedding_changed_entries, removed_records)

    total_ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[FileSync] #{length(file_entries)} files scanned in #{scan_ms}ms, " <>
        "#{length(changed_paths)} changed, validated in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{removed} removed, total #{total_ms}ms"
    )

    {:ok,
     %{
       upserted: upserted,
       removed: removed,
       changed_paths: changed_paths,
       total_files: length(file_entries)
     }}
  end

  @doc """
  Sync a single file path from the filesystem into the DB.

  Takes an absolute path, classifies it, validates if needed,
  and upserts or deletes the file record.

  Returns `{:ok, %{changed_path: path | nil}}` where path is nil if
  the file was unrecognized or ignored.
  """
  @spec sync_path(Scope.t(), String.t(), keyword()) :: {:ok, map()}
  def sync_path(%Scope{environment: env} = scope, abs_path, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, env.cwd || ".")
    rel_path = Path.relative_to(abs_path, base_dir)

    cond do
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
        sync_embeddings(scope, env, [], removed_records)
        {:ok, %{changed_path: path}}

      entry ->
        # Upsert metadata (role, owners, valid, fingerprint) but NOT mtime —
        # leaves mtime stale so sync_changed still picks the file up during
        # the stop hook pass. Fingerprint updates eagerly per Rule 8 so
        # out-of-band consumers can react to content change in real time.
        #
        # Owner resolution and component-aware validation only run for
        # roles that actually have component/story owners. Hex doc and
        # other doc-corpus files would otherwise trigger expensive
        # `list_components` + `parent_component_id IN (?,?,...)` queries
        # for every individual write — that's catastrophic when the
        # projector lands hundreds of markdown files.
        entry =
          cond do
            owner_bearing_role?(role) ->
              read_model = Files.read_model(scope)
              [entry] = Scanner.resolve_owners([entry], read_model)
              [entry] = Scanner.fingerprint_entries(env, [entry])
              Scanner.validate_entry(entry, env, read_model.component_by_id, read_model.strict?)

            setup_validated_role?(role) ->
              # Setup-config-style files (claude_md, mix_exs, credo_exs,
              # setup_config, test_support) have no component owner but DO
              # need validate_entry to populate validation_errors — the
              # Setup.* check/1 functions read those errors directly. Skip
              # owner resolution (no component) but run validation.
              [entry] = Scanner.fingerprint_entries(env, [entry])
              Scanner.validate_entry(entry, env, %{}, false)

            true ->
              [entry] = Scanner.fingerprint_entries(env, [entry])

              entry
              |> Map.put(:component_id, nil)
              |> Map.put(:story_id, nil)
              |> Map.put(:valid, true)
              |> Map.put(:validation_errors, nil)
          end

        embedding_changed_entries =
          if fingerprint_changed?(entry, existing), do: [entry], else: []

        Files.upsert_file_metadata(scope, entry)
        sync_embeddings(scope, env, embedding_changed_entries, [])
        {:ok, %{changed_path: path}}
    end
  end

  # Roles that have a meaningful component or story owner. Other
  # roles (hex_doc, project_knowledge, rule, architecture, etc.) are
  # standalone documents — there's no owner to resolve, no component
  # to look up, and no spec-alignment validation that needs running.
  defp owner_bearing_role?(role)
       when role in [:implementation, :test, :spec, :bdd_spec, :qa_brief, :qa_result, :review],
       do: true

  defp owner_bearing_role?(_), do: false

  # Roles that have no component/story owner but DO need validate_entry
  # to populate validation_errors. The Setup.* `check/1` functions
  # query these errors directly to decide whether project_setup is
  # complete; without validation the row gets `validation_errors: nil`
  # and `Setup.Context.error/4` returns the missing_msg fallback,
  # leaving the requirement permanently unsatisfied.
  defp setup_validated_role?(role)
       when role in [:claude_md, :mix_exs, :credo_exs, :setup_config, :test_support],
       do: true

  defp setup_validated_role?(_), do: false

  defp fingerprint_changed?(_entry, nil), do: true

  defp fingerprint_changed?(entry, %{fingerprint: existing_fingerprint}) do
    Map.get(entry, :fingerprint) != existing_fingerprint
  end

  # Reads each entry's content and stamps a SHA-256 fingerprint on the
  # File row. Per Story 127 Rule 8: the fingerprint is content's truth as
  # of the read; out-of-band consumers (analyzers, embedders) compare
  # File.fingerprint to their own last-seen state. mtime is the cheap
  # pre-filter that tells sync to look at a file; fingerprint is what
  # consumers gate work on.
  @doc false

  # -- Scanning (delegated) --
  #
  # These moved to `CodeMySpec.Files.Scanner`. Kept here because callers across
  # the codebase and the test suite reach for `FileSync.classify/1` and friends,
  # and the split is about where code runs, not about renaming its entry points.

  defdelegate classify(path), to: Scanner
  defdelegate stat_file(env, path, role), to: Scanner
  defdelegate stream_files(env), to: Scanner
  defdelegate fingerprint_entries(env, entries), to: Scanner
  defdelegate validate_entry(entry, env, component_by_id, strict?), to: Scanner

  @doc false
  def validate_entry(entry, env, component_by_id),
    do: Scanner.validate_entry(entry, env, component_by_id, true)

  @doc false
  def resolve_owners(scope, entries),
    do: Scanner.resolve_owners(entries, Files.read_model(scope))
end
