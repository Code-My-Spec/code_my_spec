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

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Paths
  alias CodeMySpec.Problems
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Stories
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

    with {:ok, observations} <- observe(scope, env, read_model) do
      finish_sync(scope, env, observations, start, embed?)
    end
  end

  # An environment that does not scan is not an empty working copy, and this is
  # where the two used to become the same thing. `Scanner.observe/2` answers
  # with the refusal now; carrying it out of here means every caller that
  # already writes `with {:ok, _} <- FileSync.sync(...)` gets it for free, and
  # the two that bang-match crash naming the environment rather than silently
  # deleting the projection.
  defp observe(%Scope{} = scope, env, read_model) do
    case Scanner.observe(env, read_model) do
      {:ok, observations} ->
        {:ok, observations}

      {:error, reason} ->
        # Through `scan_refusal_level/1` for the reason it exists, which applies
        # here at least as strongly: `:not_supported_on_harness` is a property of
        # the environment rather than an event, and `sync_project` now takes this
        # branch deliberately on every call against a harness-held working copy —
        # it is how the tool discovers the disk is elsewhere before asking the
        # harness to scan it. An error level would mean the tool logs a fault
        # every time it works.
        #
        # Named by working copy rather than by project id, matching `walk/2`.
        # Two checkouts of one project share the id, so the id alone cannot say
        # which of them refused.
        Logger.log(
          scan_refusal_level(reason),
          "[FileSync] #{working_copy(scope)}: refusing to sync — this environment " <>
            "cannot walk a working copy (#{inspect(reason)}). Nothing was scanned, so " <>
            "nothing is authoritative — the rows already recorded stand."
        )

        {:error, {:cannot_scan, reason}}
    end
  end

  defp finish_sync(scope, env, observations, start, embed?) do
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

    # Named by working copy. Ten of these went by for two different checkouts
    # while one of them was being emptied, and the line said which counts but
    # never which tree, so they read as one healthy sync repeating.
    Logger.info(
      "[FileSync] #{working_copy(scope)}: #{length(file_entries)} files scanned in " <>
        "#{scan_ms}ms, validated in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{length(changed_paths)} changed, " <>
        "#{removed} removed, total #{total_ms}ms"
    )

    # Files are what most of the graph is computed from, so a sync that changed
    # anything is the biggest single reason it moved. Only when something
    # actually changed: a scan that upserted nothing and removed nothing is the
    # common case on a quiet tree, and announcing it would wake the debounce for
    # a fingerprint that cannot have moved.
    #
    # `GraphWatcher` asks the fingerprint anyway, so this is an optimisation
    # rather than a correctness rule. See `Requirements.GraphInputs`.
    if changed_paths != [] or upserted > 0 or removed > 0 do
      announce_graph_change(scope, length(changed_paths), upserted, removed)
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

    # Ownership is decided here, against this server's live domain, and whatever
    # the harness worked out is discarded.
    #
    # The harness fetches its read model once, when it joins the channel. A
    # sprite joins before the project has any stories, so `story_ids` is empty
    # for the rest of the session — and `resolve_owners/2` refuses to link a
    # spex file to a story the read model has never heard of, which is the right
    # rule against a *fresh* read model and exactly wrong against a stale one.
    #
    # Drill 12 wrote 32 BDD spec files across 9 stories. All 32 synced; not one
    # carried a story id, so `bdd_specs_exist` could not pass for any story, and
    # that gates all 69 `implementation_file` requirements behind it. The agent
    # read the frozen graph as a dead file watcher — the fourth run to reach for
    # that explanation and the fourth time it was something else.
    #
    # Re-resolving here costs one read-model build per manifest and removes the
    # whole class: the harness reports what a file *is*, and the server, which
    # owns the database, decides what it *belongs to*.
    observations =
      observations
      |> Scanner.resolve_owners(Files.read_model(scope))
      |> keep_backfilled_owners(existing_by_path)

    # And record where each spex file is, for criteria that do not already say.
    # The same reasoning as re-resolving ownership above: the association should
    # live in the database rather than be re-derived from a filename every time,
    # because the filename is built from four things that all move and the two
    # directions can silently stop agreeing.
    claim_spec_paths(scope, observations)

    {upserted, changed} =
      case observations do
        [] ->
          {0, []}

        _ ->
          # Only the rows that would actually change. This used to upsert every
          # observation on every manifest — 4,157 rows re-written on a rejoin
          # where nothing on disk had moved, eight chunked `insert_all`s and the
          # index maintenance behind them. Under a rejoin loop that is what
          # exhausted the connection pool: `query_canceled ... while inserting
          # index tuple in relation "files"`, then the upgrade of the next
          # socket dying in the queue behind it (1aed7edf, 600fbb3a).
          #
          # The diff was already being computed here and used only to decide
          # what to re-embed.
          changed = changed_entries(observations, existing_by_path)

          {count, _} =
            case changed do
              [] -> {0, []}
              _ -> Files.upsert_files(scope, changed)
            end

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

    # The harness's file path, and the one that carries most real change: a
    # scan arrives as a manifest and lands here, not through `sync/2`. Hooking
    # only `finish_sync/5` announced nothing for any file an agent actually
    # wrote — measured on dev, fifteen reconciles after the watcher shipped and
    # not one announcement.
    #
    # Only when something moved. A manifest that upserted nothing, removed
    # nothing and changed nothing is the steady state of a quiet tree, and the
    # harness sends one every few minutes.
    if changed != [] or upserted > 0 or removed > 0 do
      announce_graph_change(scope, length(changed), upserted, removed)
    end

    %{
      upserted: upserted,
      removed: removed,
      changed_entries: changed,
      removed_records: removed_records
    }
  end

  @doc """
  `reconcile/2` and the component projection, committed together or not at all.

  Reconciling files is only half of a sync: the other half turns those files
  into components and writes `component_id` back onto each File row. Between the
  two, the File rows are current and the components derived from them are not —
  and a requirement check landing in that gap reads a *committed, wrong* answer
  rather than a partial one it has any way to detect. The in-flight marker
  (`ReconcileRegistry`) cannot help, because nothing about that state looks
  in-flight.

  Scope chosen on measurement: median 2.76s, p90 7.08s for the window. Postgres
  readers do not block on writers under MVCC, so including the projection costs
  a held connection rather than a stalled reader, which is what makes it
  affordable on a database several worktrees share.

  The timeout is explicit because Ecto's default 15s sits between that p90 and
  the tail — the worst possible place for it, since it would abort exactly the
  slow reconciles this exists to keep consistent.

  Caveat, written down rather than left to be discovered: `ComponentSync`
  prefers component data stored on the File row and only reads a spec over the
  wire when it is missing. Measured at 300 of 305 spec files carrying it, so a
  few still round-trip to the harness *inside* this transaction, and a stalled
  harness holds the connection for the fs timeout on each. The fix is to make
  the manifest carry data for every spec; widening the timeout again only buys
  a longer hold.

  Lives here rather than at the channel that calls it: `CodeMySpecWeb` may not
  reference `CodeMySpec.Repo`, and Boundary is right about that — a channel
  opening a database transaction is the wrong shape regardless of whether the
  compiler catches it.
  """
  @reconcile_timeout_ms 60_000

  # Two thirds of the timeout. Not tuned — chosen so a reconcile that is
  # heading for the cliff says so while there is still something to see,
  # rather than only reporting the ones that already fell off.
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
      {:ok, result} =
        Repo.transaction(
          fn ->
            summary = reconcile(scope, observations)

            %{
              upserted: summary.upserted,
              removed: summary.removed,
              changed: length(summary.changed_entries),
              components: project_components(scope, summary)
            }
          end,
          timeout: @reconcile_timeout_ms
        )

      log_duration(scope, observations, System.monotonic_time(:millisecond) - started, result)

      result
    rescue
      error ->
        log_failure(scope, observations, System.monotonic_time(:millisecond) - started, error)
        reraise error, __STACKTRACE__
    end
  end

  # The components, projected — unless no file moved, in which case they cannot
  # have.
  #
  # Used to call `ComponentSync.sync_from_files(scope)` with no scoping at
  # all — a full, non-incremental resync of every component in the project on
  # every manifest that touched even one file. `925 components synced in
  # 9000-9900ms` was that cost when this comment was written; on a
  # 1067-component project with several worktrees editing concurrently, the
  # same call was measured firing every 10-40s at 10-50s apiece, each holding
  # a pooled connection the whole time — not a one-off cost any more but a
  # standing one that does not scale with either the project or the number of
  # checkouts editing it.
  #
  # Scoped to `changed_entries` and `removed_module_names` instead: an
  # incremental resync of the components those files actually named, plus a
  # targeted orphan check for whatever a removed file named (see
  # `ComponentSync.removed_module_names/1` and `cleanup_orphaned/3`). A
  # manifest that only touches a handful of files now does a handful of
  # components' worth of work rather than the whole project's. The full,
  # non-incremental form is still what the explicit `/codemyspec:sync` and
  # `sync_project` surfaces call — this is the automatic, every-manifest path,
  # and it should not be paying the full-project price on every tick.
  #
  # Keyed on `removed` as well as `changed_entries`, because a deletion changes
  # the projection without changing any surviving row.
  #
  # Returns `:unchanged` rather than a number. The count feeds one log line, and
  # both numbers available here would be false: `0` says this project has no
  # components, and the previous run's figure reports a stale count as a fresh
  # one. Saying the projection did not run is the only true answer, and it is
  # also the one that makes the skip visible.
  defp project_components(_scope, %{changed_entries: [], removed: 0}), do: :unchanged

  defp project_components(scope, summary) do
    changed_paths = Enum.map(summary.changed_entries, & &1.path)
    removed_module_names = ComponentSync.removed_module_names(summary.removed_records)

    {:ok, components} =
      ComponentSync.sync_from_files(scope,
        changed_paths: changed_paths,
        removed_module_names: removed_module_names
      )

    length(components.all_components)
  end

  # How long the transaction took, and a warning when it is close to the limit.
  # Nothing recorded this, and its absence cost a wedged harness. When a
  # reconcile exceeds `@reconcile_timeout_ms` the transaction dies, the task
  # dies with it, and the task's death drops its pooled connection — which the
  # server logs as `Postgrex.Protocol … client #PID exited` and the harness sees,
  # three layers away, as `channel closed: {:error, %{}}`. Nothing along that
  # path names the reconcile or the timeout, so the only visible symptom is a
  # harness that rejoins forever. It took a process pinned at 126% CPU for
  # fifteen minutes and a manual restart to notice (`5be796f2`).
  #
  # Two checkouts of one project reconcile the same rows concurrently, and a
  # rejoin triggers a full rescan — so a slow transaction feeds the load that
  # made it slow. That loop is a hypothesis, not a finding; this is the
  # measurement that will confirm or kill it, which is why every reconcile
  # reports its duration and not just the ones near the limit. A single slow
  # transaction says nothing on its own; the same one getting slower says
  # everything, and that needs the ordinary case on the record too.
  #
  # At :info, beside the per-scan line above, because nothing runs at :debug —
  # dev and test both sit at :warning or :info, so a duration logged at :debug
  # is a duration nobody ever reads.
  # How much of the scan actually moved anything.
  #
  # The count beside it is how many files were *looked at*, which on a quiet
  # tree is every file every time — 4969 observations changing three rows and
  # 4969 changing eight hundred are the same line without this, and they predict
  # completely different graph work.
  # `:changed`, which `reconcile_and_project/2` already reduced to a count.
  #
  # The first version read `:changed_entries` — the key `reconcile/2` uses one
  # level down — got `nil`, defaulted to `[]`, and printed `0 changed` beside
  # `21 upserted` on every line. Two counts that cannot both be true is worse
  # than one count, because it invites the reader to distrust the pair rather
  # than the field.
  defp moved_summary(%{upserted: upserted, removed: removed, changed: changed}) do
    " — #{changed} changed, #{upserted} upserted, #{removed} removed"
  end

  defp moved_summary(_result), do: ""

  # The one line that ties a sync to the recompute it causes.
  #
  # Without it the chain breaks exactly here: `[FileSync] reconciled N
  # observations` is visible and `[Requirements] recomputed N of M` is visible,
  # and nothing says the first caused the second. Reading a graph recompute then
  # means finding the nearest preceding event and assuming — which, on a machine
  # with several agents, analyzer runs and deploys interleaved, produced two
  # confidently wrong diagnoses in one evening: analyzer completions blamed for
  # full computes that were deploys, and readers blamed for overwriting a
  # topology fingerprint that was simply never written.
  #
  # `reconciled N observations` cannot stand in for it either. N is how many
  # files were *looked at*: 4969 observations with three changed rows and 4969
  # with eight hundred read identically, and they predict completely different
  # graph work.
  defp announce_graph_change(scope, changed, upserted, removed) do
    obs = GraphInputs.observation_id()

    Logger.info(
      "[FileSync] announcing a graph change for #{working_copy(scope)} — " <>
        "#{changed} changed, #{upserted} upserted, #{removed} removed",
      obs: obs
    )

    GraphInputs.changed(scope, obs)
  end

  defp log_duration(scope, observations, ms, result) do
    count = length(observations)
    copy = working_copy(scope)
    moved = moved_summary(result)

    if ms >= @reconcile_slow_ms do
      Logger.warning(
        "[FileSync] reconciled #{count} observations for #{copy} in #{ms}ms — within " <>
          "#{@reconcile_timeout_ms - ms}ms of the #{@reconcile_timeout_ms}ms transaction " <>
          "timeout. Past it the transaction dies, its task dies, and the channel closes " <>
          "with it; the harness then rejoins and rescans everything, which is the same " <>
          "load again. See 5be796f2."
      )
    else
      Logger.info("[FileSync] reconciled #{count} observations for #{copy} in #{ms}ms#{moved}")
    end
  end

  # Name the reconcile on its way past, then let it crash.
  #
  # This rescue swallows nothing — it reraises with the original stacktrace, so
  # every caller behaves exactly as before. It exists because the one thing this
  # failure does not do is say what it was. `Repo.transaction/2` raises on
  # timeout rather than returning an error tuple, so the crash carries the
  # connection's vocabulary ("tcp recv: timeout") and none of ours: not the file
  # count, not the working copy, not the word "reconcile". Three frames later it
  # is a closed channel, and the harness reports that as a server crash.
  #
  # A near-miss warning alone would not have covered this. It fires at
  # @reconcile_slow_ms on the way *up*, which helps only when something survives
  # to log it — and the case worth catching is precisely the one where nothing
  # does.
  defp log_failure(scope, observations, ms, error) do
    Logger.error(
      "[FileSync] reconcile of #{length(observations)} observations for " <>
        "#{working_copy(scope)} FAILED after #{ms}ms (timeout is " <>
        "#{@reconcile_timeout_ms}ms): #{Exception.message(error)}. If this was the " <>
        "timeout, the task dies with the transaction and takes its pooled connection " <>
        "with it, which closes the harness channel; the rejoin rescans everything and " <>
        "arrives back here. See 5be796f2."
    )
  end

  # Which checkout a line is about. Every row this module writes is keyed on the
  # harness, so every line it logs should say which one — `cwd` when the scope
  # has it, the harness id otherwise, since a server-side scope has no path.
  defp working_copy(%Scope{cwd: cwd}) when is_binary(cwd), do: cwd
  defp working_copy(%Scope{active_working_copy_id: id}) when is_binary(id), do: "harness #{id}"
  defp working_copy(_scope), do: "an unnamed working copy"

  # Entries whose fingerprint differs from the existing DB row (or that
  # have no row yet) — i.e., files whose content actually changed since
  # the last sync. Used to drive embedding work and to populate the
  # user-visible "Changed files" count on the /files page.
  # Only files whose name still yields a criterion id, which is every file the
  # convention produced. One that does not is either a criterion that has been
  # cut or a file named by hand, and neither should have a path invented for it.
  defp claim_spec_paths(scope, observations) do
    paths =
      observations
      |> Enum.filter(&(Map.get(&1, :role) == :bdd_spec))
      |> Enum.flat_map(fn entry ->
        case Parser.derive_criterion_id(entry.path) do
          nil -> []
          id -> [{id, entry.path}]
        end
      end)
      |> Map.new()

    case AcceptanceCriteria.claim_spec_paths(scope, paths) do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        Logger.info(
          "[FileSync] recorded the spex path for #{n} criteri#{if n == 1, do: "on", else: "a"} " <>
            "that had none — their files are now found by record rather than by name"
        )
    end
  end

  # A `nil` from `resolve_owners/2` means "I have no rule for this file", not
  # "this file has no owner", and the two must not be written the same way.
  #
  # `component_id` has a second writer. `ComponentSync.backfill_file_owners/2`
  # claims `test/<path>_test.exs` for the component it tests, and by declared
  # module for the Phoenix files whose location does not match their name — and
  # it is careful never to steal, matching only `is_nil(f.component_id)`.
  # `resolve_owners/2` cannot make that link at all: it matches a file's
  # declared module against `component_by_module`, and a test file declares
  # `CodeMySpec.Git.CLITest` while the component is `CodeMySpec.Git.CLI`. So it
  # answered `nil` for every test file, wrote that over the backfill, and the
  # backfill put it back inside the same transaction. Next scan, again — an
  # oscillation that ran on every sync of every working copy (`d698ab0e`).
  #
  # Preserving costs nothing in correctness: the end state is what it already
  # was, because the backfill won every round anyway. What goes is the write
  # that was always immediately undone, and with it the two rows that made
  # `changed_entries` permanently non-empty and kept the component projection
  # from ever skipping.
  #
  # `story_id` is deliberately not preserved. Nothing else writes it, so a `nil`
  # there really is this function's answer — a spex file whose criterion was
  # deleted should lose its story, and holding the old one would be the mirror
  # bug.
  defp keep_backfilled_owners(observations, existing_by_path) do
    Enum.map(observations, fn entry ->
      with nil <- Map.get(entry, :component_id),
           %{component_id: stored} when not is_nil(stored) <-
             Map.get(existing_by_path, entry.path) do
        Map.put(entry, :component_id, stored)
      else
        _ -> entry
      end
    end)
  end

  # Entries the stored row does not already say.
  #
  # This used to compare the fingerprint alone, which was right for its original
  # job — deciding what to re-embed — and wrong for the one it has now, deciding
  # what to write. Ownership is re-resolved here on every manifest against the
  # server's live read model, so a spex file whose story was created *after* the
  # harness joined gets a `story_id` with its content untouched and its
  # fingerprint identical. Judged on fingerprint, that entry is unchanged and
  # would never be written, and `bdd_specs_exist` would stay dark on a story
  # whose spec file is right there on disk — the Drill 12 failure, which this
  # codebase has read as a dead file watcher four times.
  #
  # So the comparison is every column an upsert would overwrite, taken from
  # `Files.replaceable_fields/0` rather than restated here. A field added to the
  # upsert is compared from the moment it is added.
  #
  # A missing key is not "equal to nil": an entry that omits a field it does not
  # know about must not silently claim the stored value. `Map.fetch/2` says
  # which, and an absent key counts as a difference — the safe direction, since
  # the cost is writing a row that did not need it.
  defp changed_entries(entries, existing_by_path) do
    fields = Files.replaceable_fields()

    changed =
      Enum.filter(entries, fn entry ->
        case Map.get(existing_by_path, entry.path) do
          nil -> true
          record -> Enum.any?(fields, &differs?(entry, record, &1))
        end
      end)

    explain_changes(changed, existing_by_path, fields)
    changed
  end

  # Below this many, say which files changed and on which field. Above it, the
  # count is the story and per-file lines would be thousands of them.
  @explain_changes_below 10

  # Why these rows are being written.
  #
  # A row that reports itself changed on every scan while the file never moves
  # is a false positive, and it is invisible by construction: the write happens,
  # the answer stays correct, and the only symptom is work that did not need
  # doing plus a component projection that never gets to skip. Two files did
  # exactly that on the day the diff shipped, matching on every column an
  # inspection could see — and finding the field by guessing failed twice.
  #
  # At :info rather than :debug because the `web.log` handler is pinned at
  # :info, so a debug line here reaches nobody. The threshold is what makes that
  # affordable: a steady state changes a handful of files, and a bulk sync says
  # nothing per-file at all.
  defp explain_changes([], _existing_by_path, _fields), do: :ok

  defp explain_changes(changed, _existing_by_path, _fields)
       when length(changed) >= @explain_changes_below,
       do: :ok

  defp explain_changes(changed, existing_by_path, fields) do
    detail =
      Enum.map_join(
        changed,
        "; ",
        &explain_change(&1, Map.get(existing_by_path, &1.path), fields)
      )

    Logger.info("[FileSync] writing #{length(changed)} row(s) — #{detail}")
  end

  defp explain_change(entry, nil, _fields), do: "#{entry.path}: new"

  defp explain_change(entry, record, fields) do
    reasons =
      fields
      |> Enum.filter(&differs?(entry, record, &1))
      |> Enum.map_join(", ", &describe_difference(entry, record, &1))

    "#{entry.path}: #{reasons}"
  end

  defp describe_difference(entry, record, field) do
    "#{field} #{inspect(Map.get(entry, field), limit: 2)} != " <>
      "#{inspect(Map.get(record, field), limit: 2)}"
  end

  defp differs?(entry, record, field) do
    case Map.fetch(entry, field) do
      {:ok, value} -> value != Map.get(record, field)
      :error -> true
    end
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
    with {:ok, stream} <- walk(scope, env) do
      finish_sync_changed(scope, env, Enum.to_list(stream), start)
    end
  end

  # The stop hook's entry into the same trap `sync/2` was in, and the one the
  # `scannable/1` comment named by name. It ran on every stop, so it is the
  # deletion that actually fired: `0 files scanned … 3937 removed`, four minutes
  # after the fix to `sync/2` went live and while the harness was healthy.
  defp walk(%Scope{} = scope, env) do
    case Scanner.stream_files(env) do
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

  # The refusal is identical either way; only how loudly it is said changes.
  #
  # `:not_supported_on_harness` is a property of the environment, not an event.
  # `Environments.Harness` returns it from `stream_files/3` unconditionally —
  # a working copy on another machine has no disk here to walk — so a
  # harness-backed copy takes this branch on **every stop hook** and it never
  # means anything went wrong. Measured 2026-08-20: 193 error-level lines in one
  # `web.log`, 165 for the main checkout and 28 for a worktree, and the top four
  # entries by volume in that log were this and its consequences. Finding a real
  # error in there meant bucketing by message shape first.
  #
  # A scan that failed for any other reason is an event and keeps `:error`.
  #
  # Only the level moves. The message, the `{:error, {:cannot_scan, reason}}`
  # return and the refusal itself are untouched, and that is deliberate: the
  # `scannable/1` clause that used to fold this into `[]` deleted 3936 rows and
  # 452 Problems, twice, because "could not look" reached the caller as "nothing
  # is there". Quieting a log line is safe; letting the caller believe the scan
  # happened is what was not.
  # Public so the decision can be asserted directly. The suite pins the global
  # Logger at `:warning`, so an `:info` line never reaches `CaptureLog` and the
  # quiet branch is unobservable through the log — testing it there would assert
  # only that nothing was captured, which is equally true of a line that was
  # never written.
  #
  # `observe/3` above keeps `:error` for the same reason this one does not: it
  # is `sync/2`'s path — a manual full sync or app boot — and fired twice in the
  # log this came from, against `walk/2`'s 197. Rare and operator-initiated is
  # exactly when an error level earns its keep.
  @doc "The log level for a scan refusal — `:info` for a routine one, `:error` otherwise."
  def scan_refusal_level(:not_supported_on_harness), do: :info
  def scan_refusal_level(_reason), do: :error

  defp finish_sync_changed(%Scope{} = scope, env, file_entries, start) do
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

    clear_specs_ready_for_rewritten_specs(scope, embedding_changed_entries, removed_records)

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

  # Chain restart: rewriting a story's BDD specs changes the contract, so
  # whatever a previous green run proved no longer applies and the story
  # has to earn specs-ready again.
  #
  # Keyed on the *fingerprint*-changed set, not the mtime-changed set — a
  # byte-identical rewrite (a `touch`, a reformat that lands identical
  # bytes) is not a contract change and must not knock a shipped story out
  # of enforcement. Deletions count too: dropping a spec file changes the
  # contract as surely as editing one.
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
  # This is every role `Scanner.validate_entry/4` has a clause for that is not
  # owner-bearing. It was five, and the three that were missing —
  # `:qa_plan`, `:persona_summary`, `:persona_sources` — fell to the branch
  # below that stamps `valid: true` without reading the file.
  #
  # That made the two sync paths disagree. A full scan validated them; a single
  # path write, which is what the watcher fires and what an agent's edit goes
  # through, marked them valid unconditionally. So a QA plan missing every
  # required section came back valid until something happened to trigger a full
  # scan, and `qa_setup` — "QA plan exists with App Overview, Tools Registry,
  # and Seed Strategy" — was satisfied by a file that had none of them.
  defp setup_validated_role?(role)
       when role in [
              :claude_md,
              :mix_exs,
              :credo_exs,
              :setup_config,
              :test_support,
              :qa_plan,
              :persona_summary,
              :persona_sources
            ],
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

  @doc "Convenience over `validate_entry/4` defaulting `strict?` to true."
  def validate_entry(entry, env, component_by_id),
    do: Scanner.validate_entry(entry, env, component_by_id, true)

  @doc "Convenience over `Scanner.resolve_owners/2` that builds the read model from `scope`."
  def resolve_owners(scope, entries),
    do: Scanner.resolve_owners(entries, Files.read_model(scope))
end
