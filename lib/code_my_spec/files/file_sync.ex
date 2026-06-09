defmodule CodeMySpec.Files.FileSync do
  @moduledoc """
  Synchronizes the filesystem into File records using DirWalker.

  Streams the project directory, classifies each file by path pattern,
  stats for mtime/size, and upserts File records. Returns which files changed.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Configurations
  alias CodeMySpec.Documents
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Paths
  alias CodeMySpec.Problems
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
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
  @sync_roots ["lib", "test", Paths.base_dir(), "CLAUDE.md", "mix.exs", ".credo.exs"]

  @ignored_dirs ~w(deps _build .git node_modules .elixir_ls .lexical)

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

    file_entries =
      env
      |> stream_files()
      |> Enum.to_list()

    scan_ms = System.monotonic_time(:millisecond) - start

    # Snapshot existing rows up front so we can compute fingerprint diffs
    # (real "changed paths") and capture the role of files that are about
    # to be removed (so embedding cleanup knows the source/path tuple).
    existing_records = Files.list_files(scope)
    existing_by_path = Map.new(existing_records, &{&1.path, &1})

    {upserted, changed_entries} =
      case file_entries do
        [] ->
          {0, []}

        _ ->
          entries_with_owners = resolve_owners(scope, file_entries)
          entries_with_fingerprints = fingerprint_entries(env, entries_with_owners)

          components = Components.list_components(scope)
          component_by_id = Map.new(components, &{&1.id, &1})
          strict? = Configurations.require_specs?(scope)

          validated_entries =
            Enum.map(
              entries_with_fingerprints,
              &validate_entry(&1, env, component_by_id, strict?)
            )

          changed = changed_entries(validated_entries, existing_by_path)

          {count, _} = Files.upsert_files(scope, validated_entries)
          {count, changed}
      end

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

    Logger.info(
      "[FileSync] embed_only: #{length(embeddable_records)} files in #{elapsed}ms"
    )

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
          entries_with_owners = resolve_owners(scope, mtime_changed_entries)
          entries_with_fingerprints = fingerprint_entries(env, entries_with_owners)

          components = Components.list_components(scope)
          component_by_id = Map.new(components, &{&1.id, &1})
          strict? = Configurations.require_specs?(scope)

          validated_entries =
            Enum.map(
              entries_with_fingerprints,
              &validate_entry(&1, env, component_by_id, strict?)
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
      ignored_path?(rel_path) ->
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
              [entry] = resolve_owners(scope, [entry])
              [entry] = fingerprint_entries(env, [entry])
              components = Components.list_components(scope)
              component_by_id = Map.new(components, &{&1.id, &1})
              strict? = Configurations.require_specs?(scope)
              validate_entry(entry, env, component_by_id, strict?)

            setup_validated_role?(role) ->
              # Setup-config-style files (claude_md, mix_exs, credo_exs,
              # setup_config, test_support) have no component owner but DO
              # need validate_entry to populate validation_errors — the
              # Setup.* check/1 functions read those errors directly. Skip
              # owner resolution (no component) but run validation.
              [entry] = fingerprint_entries(env, [entry])
              validate_entry(entry, env, %{}, false)

            true ->
              [entry] = fingerprint_entries(env, [entry])
              entry |> Map.put(:component_id, nil) |> Map.put(:story_id, nil) |> Map.put(:valid, true) |> Map.put(:validation_errors, nil)
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
  def fingerprint_entries(env, entries) do
    Enum.map(entries, &add_fingerprint(env, &1))
  end

  defp add_fingerprint(env, entry) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} -> Map.put(entry, :fingerprint, fingerprint(content))
      {:error, _} -> Map.put(entry, :fingerprint, nil)
    end
  end

  defp fingerprint(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Stream and classify all trackable files under the sync whitelist roots.

  Returns a stream of maps with `:path`, `:role`, `:mtime`, `:size`. Paths are
  relative to `env.cwd`.
  """
  @spec stream_files(Environments.Environment.t()) :: Enumerable.t()
  def stream_files(env) do
    env
    |> Environments.stream_files(@sync_roots)
    |> Stream.map(&classify/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn {path, role} -> stat_file(env, path, role) end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Validate a file entry based on its role.

  Specs and reviews are validated via `Documents.create_dynamic_document`.
  Tests with a component are checked for spec alignment.
  Other tracked roles are valid by existence.
  """
  def validate_entry(entry, env, component_by_id, strict? \\ true)

  def validate_entry(%{role: :spec} = entry, env, _component_by_id, strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        document_type = document_type_from_content(content)
        validate_spec_content(entry, content, document_type, strict?)

      {:error, reason} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: "Read failed: #{inspect(reason)}"}})
    end
  end

  def validate_entry(%{role: :review} = entry, env, _component_by_id, strict?) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        validate_spec_content(entry, content, "design_review", strict?)

      {:error, reason} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: "Read failed: #{inspect(reason)}"}})
    end
  end

  def validate_entry(%{role: :test, component_id: component_id} = entry, env, component_by_id, _strict?)
       when not is_nil(component_id) do
    component = Map.get(component_by_id, component_id)

    if component do
      validate_test_alignment(entry, env, component)
    else
      Map.merge(entry, %{valid: true, validation_errors: nil})
    end
  end

  # Setup artifacts: each validator runs all the per-concern checks the setup
  # steps used to do at evaluate-time, and persists the results into
  # `validation_errors` keyed by concern. The corresponding Setup.* step then
  # decides pass/fail by reading those keys — zero filesystem access.
  def validate_entry(%{role: :mix_exs} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_mix_exs/1)
  end

  def validate_entry(%{role: :credo_exs} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_credo_exs/1)
  end

  def validate_entry(%{role: :claude_md} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_claude_md/1)
  end

  def validate_entry(%{role: :setup_config} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_setup_config/1)
  end

  def validate_entry(%{role: :test_support} = entry, env, _component_by_id, _strict?) do
    validate_setup_file(entry, env, &validate_test_support(&1, entry.path))
  end

  @valid_by_existence_roles [
    :implementation,
    :test,
    :rule,
    :config,
    :bdd_spec,
    :qa_brief,
    :qa_result,
    :json,
    :review,
    :architecture,
    :integration,
    :agents_md,
    :project_knowledge,
    :hex_doc
  ]

  def validate_entry(%{role: role} = entry, _env, _component_by_id, _strict?)
      when role in @valid_by_existence_roles do
    # These roles are valid if they exist (which they do, since FileSync found them)
    Map.merge(entry, %{valid: true, validation_errors: nil})
  end

  def validate_entry(entry, _env, _component_by_id, _strict?) do
    Map.merge(entry, %{valid: nil, validation_errors: nil})
  end

  defp validate_test_alignment(entry, env, component) do
    module_path = Macro.underscore(component.module_name) |> String.replace(".", "/")
    spec_path = Paths.spec_file(module_path)

    with {:ok, spec_content} <- Environments.read_file(env, spec_path),
         {:ok, test_content} <- Environments.read_file(env, entry.path) do
      case SpecAlignment.check_test_alignment(spec_content, test_content) do
        {:ok, :aligned} ->
          Map.merge(entry, %{valid: true, validation_errors: nil})

        {:ok, :misaligned, errors} ->
          Map.merge(entry, %{valid: false, validation_errors: errors})
      end
    else
      {:error, _} ->
        # No spec file or can't read test — valid by default
        Map.merge(entry, %{valid: true, validation_errors: nil})
    end
  end

  # -- Setup-artifact validators --
  #
  # Each validator returns `%{errors: map, data: map}`:
  # - `errors` keys are concerns (atom-stringified by JSON when round-tripping
  #   the DB :map column). Value `nil` = concern passes; string = fail message.
  # - `data` keys are facts (e.g. extracted app_name) that other Setup.* steps
  #   need to consume. Not part of validity.
  #
  # `valid` is true iff every value in `errors` is nil. Setup.* steps read both
  # maps off the persisted File record's `validation_errors` and use the data
  # for cross-file decisions (e.g. TestSupportNamespace needs app_name from
  # mix_exs to know what namespace to look for in conn_case / data_case).

  defp validate_setup_file(entry, env, validator) do
    case Environments.read_file(env, entry.path) do
      {:ok, content} ->
        %{errors: errors, data: data} = validator.(content)
        all_pass? = Enum.all?(errors, fn {_, v} -> is_nil(v) end)

        Map.merge(entry, %{
          valid: all_pass?,
          validation_errors: %{"errors" => stringify_keys(errors), "data" => stringify_keys(data)}
        })

      {:error, reason} ->
        Map.merge(entry, %{
          valid: false,
          validation_errors: %{
            "errors" => %{"read" => "Read failed: #{inspect(reason)}"},
            "data" => %{}
          }
        })
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @required_mix_deps [:credo, :client_utils, :sobelow, :sexy_spex, :boundary, :code_my_spec_generators]

  defp validate_mix_exs(content) do
    {app_name_value, app_name_error} = extract_app_name_result(content)

    %{
      errors: %{
        app_name: app_name_error,
        compilers: validate_compilers(content),
        codemyspec_deps: validate_codemyspec_deps(content),
        spex_config: validate_spex_config(content)
      },
      data: %{app_name: app_name_value}
    }
  end

  defp extract_app_name_result(content) do
    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> {name, nil}
      _ -> {nil, "Cannot extract app name from `mix.exs`"}
    end
  end

  defp validate_compilers(content) do
    has_boundary = Regex.match?(~r/compilers.*:boundary/s, content)
    has_spex = Regex.match?(~r/compilers.*:spex/s, content)

    if has_boundary and has_spex,
      do: nil,
      else: "Compilers not configured in `mix.exs` (need :boundary and :spex)"
  end

  defp validate_codemyspec_deps(content) do
    missing =
      Enum.reject(@required_mix_deps, fn dep ->
        Regex.match?(~r/\{:#{Atom.to_string(dep)}[,\s]/, content)
      end)

    if missing == [],
      do: nil,
      else: "Missing deps in `mix.exs`: #{Enum.map_join(missing, ", ", &":#{&1}")}"
  end

  defp validate_spex_config(content) do
    if Regex.match?(~r/spex:\s*:test/, content),
      do: nil,
      else: "`spex: :test` not found in preferred_envs in `mix.exs`"
  end

  defp validate_credo_exs(content) do
    has_requires =
      String.contains?(content, "credo_checks/framework") and
        String.contains?(content, "credo_checks/local")

    has_eval = String.contains?(content, "credo_checks/framework/checks.exs")

    error =
      if has_requires and has_eval do
        nil
      else
        "`.credo.exs` missing custom check configuration (requires + eval_file)"
      end

    %{errors: %{custom_checks: error}, data: %{}}
  end

  defp validate_claude_md(content) do
    error =
      if String.contains?(content, "<!-- code_my_spec:start -->") do
        nil
      else
        "`CLAUDE.md` exists but missing CodeMySpec managed section"
      end

    %{errors: %{managed_section: error}, data: %{}}
  end

  defp validate_setup_config(content) do
    error =
      case YamlElixir.read_from_string(content) do
        {:ok, _} -> nil
        _ -> "`.code_my_spec/config.yml` is not valid YAML"
      end

    %{errors: %{config_yaml: error}, data: %{}}
  end

  # test/support files: which checks apply depends on filename. Dispatch on
  # basename so each variant is a focused function. conn_case/data_case can't
  # decide validity unilaterally (depends on app name from mix_exs), so they
  # store the module name in `data` and the step does the cross-file compare.
  defp validate_test_support(content, path) do
    do_validate_test_support(Path.basename(path), content, path)
  end

  defp do_validate_test_support("conn_case.ex", content, path),
    do: validate_test_support_case(content, path)

  defp do_validate_test_support("data_case.ex", content, path),
    do: validate_test_support_case(content, path)

  defp do_validate_test_support(base, content, path) do
    case test_support_kind(base) do
      :boundary -> validate_test_support_boundary(content, path)
      :spex_case -> validate_test_support_spex_case(content, path)
      :unknown -> %{errors: %{}, data: %{}}
    end
  end

  defp test_support_kind(base) do
    cases = [
      {"_spex.ex", :boundary},
      {"_test_boundary.ex", :boundary},
      {"_spex_case.ex", :spex_case}
    ]

    Enum.find_value(cases, :unknown, fn {suffix, kind} ->
      if String.ends_with?(base, suffix), do: kind
    end)
  end

  defp validate_test_support_boundary(content, path) do
    error =
      if String.contains?(content, "use Boundary"),
        do: nil,
        else: "Missing `use Boundary` in `#{path}`"

    %{errors: %{has_use_boundary: error}, data: %{}}
  end

  defp validate_test_support_spex_case(content, path) do
    required = ["use SexySpex", "import Phoenix.LiveViewTest"]
    defmodule_ok = Regex.match?(~r/defmodule \S+Spex\.Case/, content)
    missing = Enum.reject(required, &String.contains?(content, &1))

    %{errors: %{spex_case_module: spex_case_error(defmodule_ok, missing, path)}, data: %{}}
  end

  defp spex_case_error(false, _missing, path),
    do: "`#{path}` missing `defmodule <App>Spex.Case`"

  defp spex_case_error(true, [], _path), do: nil

  defp spex_case_error(true, missing, path),
    do: "`#{path}` missing: #{Enum.join(missing, ", ")}"

  defp validate_test_support_case(content, path) do
    module_name =
      case Regex.run(~r/defmodule\s+(\S+)\b/, content) do
        [_, mod] -> mod
        _ -> nil
      end

    error = if module_name, do: nil, else: "`#{path}` has no defmodule"

    %{errors: %{has_defmodule: error}, data: %{module_name: module_name}}
  end

  defp validate_spec_content(entry, content, document_type, strict?) do
    case Documents.create_dynamic_document(content, document_type, strict: strict?) do
      {:ok, _document} ->
        Map.merge(entry, %{valid: true, validation_errors: nil})

      {:error, error} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: to_string(error)}})
    end
  rescue
    e ->
      Map.merge(entry, %{valid: false, validation_errors: %{error: Exception.message(e)}})
  end

  # Extract document type from spec content's ## Type section.
  # Maps component types to document types via the registry.
  defp document_type_from_content(content) do
    type_section =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    case type_section do
      nil -> "spec"
      component_type ->
        type_def = ComponentRegistry.get_type(component_type)
        Map.get(type_def, :document_type, "spec")
    end
  end

  @doc """
  Classify a relative path into a file role.

  Returns `{path, role}` or `nil` if the path doesn't match any known pattern.
  """
  @spec classify(String.t()) :: {String.t(), atom()} | nil
  def classify(path) do
    Enum.find_value(
      [
        &classify_setup_artifact/1,
        &classify_spec_or_review/1,
        &classify_code/1,
        &classify_docs/1,
        &classify_qa/1,
        &classify_config/1
      ],
      & &1.(path)
    )
  end

  # Setup-time artifacts. Validated at sync time so the requirements graph
  # can decide `project_setup` satisfaction with O(1) DB lookups instead of
  # re-reading these files on every render.
  defp classify_setup_artifact(path) do
    cond do
      path == "mix.exs" -> {path, :mix_exs}
      path == ".credo.exs" -> {path, :credo_exs}
      path == "CLAUDE.md" -> {path, :claude_md}
      path == Path.join(Paths.base_dir(), "AGENTS.md") -> {path, :agents_md}
      path == Path.join(Paths.base_dir(), "config.yml") -> {path, :setup_config}
      test_support?(path) -> {path, :test_support}
      true -> nil
    end
  end

  # Five files in test/support/ are setup artifacts (boundary defs, ConnCase/
  # DataCase, the Spex.Case template). The first three are app-name-prefixed.
  defp test_support?(path) do
    base = Path.basename(path)

    String.starts_with?(path, "test/support/") and
      (String.ends_with?(base, "_spex.ex") or
         String.ends_with?(base, "_test_boundary.ex") or
         String.ends_with?(base, "_spex_case.ex") or
         base == "conn_case.ex" or
         base == "data_case.ex")
  end

  defp classify_spec_or_review(path) do
    spec_prefix = Paths.spec_dir() <> "/"

    cond do
      String.starts_with?(path, spec_prefix) and String.ends_with?(path, ".spec.md") ->
        {path, :spec}

      String.starts_with?(path, spec_prefix) and String.ends_with?(path, "/design_review.md") ->
        {path, :review}

      true ->
        nil
    end
  end

  defp classify_code(path) do
    cond do
      String.starts_with?(path, "test/spex/") and String.ends_with?(path, "_spex.exs") ->
        {path, :bdd_spec}

      String.starts_with?(path, "test/") and String.ends_with?(path, "_test.exs") ->
        {path, :test}

      String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex") ->
        {path, :implementation}

      true ->
        nil
    end
  end

  # Each tuple is `{dir_fn, role}` — a path under that directory ending
  # in `.md` classifies as that role. Order doesn't matter; the dirs
  # don't overlap.
  #
  # Framework knowledge (the `"knowledge"` source) is intentionally
  # absent — it lives in `priv/knowledge/` and is embedded directly
  # by `Embeddings.sync_framework_knowledge/1`. Nothing under the
  # project tree resolves to that role.
  defp doc_dir_roles do
    [
      {&Paths.rules_dir/0, :rule},
      {&Paths.architecture_dir/0, :architecture},
      {&Paths.integrations_dir/0, :integration},
      {&Paths.knowledge_dir/0, :project_knowledge},
      {&Paths.hex_docs_dir/0, :hex_doc}
    ]
  end

  defp classify_docs(path) do
    if String.ends_with?(path, ".md"),
      do: Enum.find_value(doc_dir_roles(), &match_doc_dir(path, &1))
  end

  defp match_doc_dir(path, {dir_fn, role}) do
    if String.starts_with?(path, dir_fn.() <> "/"), do: {path, role}
  end

  defp classify_qa(path) do
    cond do
      match_qa_file?(path, "brief.md") -> {path, :qa_brief}
      match_qa_result?(path) -> {path, :qa_result}
      true -> nil
    end
  end

  defp classify_config(path) do
    if path == Path.join(Paths.tasks_dir(), "code_generation.sh"),
      do: {path, :task_artifact}
  end

  # -- Private --

  defp ignored_path?(path) do
    first_segment = path |> String.split("/") |> hd()
    first_segment in @ignored_dirs
  end


  # .code_my_spec/qa/{story_id}/brief.md
  defp match_qa_file?(path, filename) do
    qa_prefix = Paths.qa_dir() <> "/"
    String.starts_with?(path, qa_prefix) and String.ends_with?(path, "/" <> filename)
  end

  # Only result_complete.md satisfies the :qa_result role. In-progress
  # (result.md) and archived failures (result_failed_<ts>.md) live on disk
  # but aren't role-tagged — qa_complete must not be satisfied by an
  # unfinished or failed run.
  defp match_qa_result?(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    String.starts_with?(path, qa_prefix) and
      Path.basename(path) == "result_complete.md"
  end

  @doc "Stat a file for mtime and size. Returns entry map or nil if file doesn't exist."
  def stat_file(env, path, role) do
    case Environments.stat(env, path) do
      {:ok, %{mtime: mtime, size: size}} ->
        %{path: path, role: role, mtime: mtime, size: size}

      {:error, _} ->
        nil
    end
  end

  @doc "Resolve component_id and story_id owners for file entries."
  def resolve_owners(scope, entries) do
    # Build component lookup: module_name → component_id
    components = Components.list_components(scope)
    component_by_module = Map.new(components, &{&1.module_name, &1.id})

    # Build story lookup: story_id (integer) for qa/bdd_spec files
    story_ids = extract_story_ids(entries)
    story_by_id = load_stories_by_id(scope, story_ids)

    Enum.map(entries, fn entry ->
      {component_id, story_id} =
        owner_for(entry.path, entry.role, component_by_module, story_by_id)

      Map.merge(entry, %{component_id: component_id, story_id: story_id})
    end)
  end

  defp owner_for(path, role, component_by_module, _story_by_id)
       when role in [:implementation, :test, :spec] do
    module_name = path_to_module_name(path, role)
    {Map.get(component_by_module, module_name), nil}
  end

  defp owner_for(path, :bdd_spec, _component_by_module, story_by_id) do
    # test/spex/{story_id_and_title}/criterion_*_spex.exs → story
    story_id = extract_story_id_from_spex_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(path, role, _component_by_module, story_by_id)
       when role in [:qa_brief, :qa_result] do
    # .code_my_spec/qa/{story_id}/brief.md → story
    story_id = extract_story_id_from_qa_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(path, :review, component_by_module, _story_by_id) do
    # .code_my_spec/spec/metric_flow/integrations/design_review.md → MetricFlow.Integrations
    module_name =
      path
      |> String.replace_prefix(Paths.spec_dir() <> "/", "")
      |> Path.dirname()
      |> path_segments_to_module()

    {Map.get(component_by_module, module_name), nil}
  end

  defp owner_for(_path, _role, _component_by_module, _story_by_id), do: {nil, nil}

  # .code_my_spec/qa/440/brief.md → 440
  defp extract_story_id_from_qa_path(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    path
    |> String.replace_prefix(qa_prefix, "")
    |> String.split("/")
    |> hd()
    |> parse_integer()
  end

  # test/spex/424_user_registration.../criterion_*_spex.exs → 424
  defp extract_story_id_from_spex_path(path) do
    path
    |> String.replace_prefix("test/spex/", "")
    |> String.split("/")
    |> hd()
    |> String.split("_")
    |> hd()
    |> parse_integer()
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp extract_story_ids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case entry.role do
        :bdd_spec -> [extract_story_id_from_spex_path(entry.path)]
        role when role in [:qa_brief, :qa_result] -> [extract_story_id_from_qa_path(entry.path)]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_stories_by_id(_scope, []), do: %{}

  defp load_stories_by_id(scope, story_ids) do
    import Ecto.Query

    CodeMySpec.Stories.Story
    |> where([s], s.project_id == ^scope.active_project_id and s.id in ^story_ids)
    |> select([s], {s.id, s.id})
    |> CodeMySpec.Repo.all()
    |> Map.new()
  end

  defp path_to_module_name(path, :implementation) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :test) do
    path
    |> String.replace_prefix("test/", "")
    |> String.replace_suffix("_test.exs", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :spec) do
    path
    |> String.replace_prefix(Paths.spec_dir() <> "/", "")
    |> String.replace_suffix(".spec.md", "")
    |> path_segments_to_module()
  end

  defp path_segments_to_module(path) do
    path
    |> String.split("/")
    |> strip_convention_dirs()
    |> Enum.map_join(".", fn segment ->
      segment
      |> String.split("_")
      |> Enum.map_join(&String.capitalize/1)
    end)
  end

  # Phoenix convention: `live/` and `controllers/` are directory-only conventions
  # that don't map to module namespace segments.
  # e.g. "metric_flow_web/live/user_live/login" → "metric_flow_web/user_live/login"
  # Only strip when the convention dir is the second segment (directly under the web root).
  defp strip_convention_dirs([root, convention | rest])
       when convention in ["live", "controllers"] do
    [root | rest]
  end

  defp strip_convention_dirs(segments), do: segments
end
