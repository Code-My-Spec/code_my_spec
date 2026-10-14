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

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.ProjectKnowledgeReconciler
  alias CodeMySpec.Environments
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
    case Keyword.fetch(opts, :environment) do
      {:ok, env} -> env
      :error -> WorkingCopies.environment(scope)
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

    # One read model for the whole pass. The pre-split code queried components
    # twice — once for ownership, once for validation — and the config flag
    # separately; scanning now states what it needs and gets it once.
    read_model = Files.read_model(scope)

    with {:ok, observations} <- observe(scope, env, read_model) do
      finish_sync(scope, observations, start, env)
    end
  end

  # An environment that does not scan is not an empty working copy, and this is
  # where the two used to become the same thing. `Scanner.observe/2` answers
  # with the refusal now; carrying it out of here means every caller that
  # already writes `with {:ok, _} <- FileSync.sync(...)` gets it for free, and
  # the two that bang-match crash naming the environment rather than silently
  # deleting the projection.
  defp observe(%Scope{} = scope, env, read_model) do
    case if(is_nil(env), do: {:error, :no_environment}, else: Scanner.observe(env, read_model)) do
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

  Split out because the two halves need different machines. Observing has to
  happen where the files are; this needs only the database, and a harness that
  holds none can send its observations here instead of writing rows itself.

  Note that it takes the *whole* observation set rather than a delta. That is
  what lets it tell a deletion from an omission — a stream of per-file updates
  cannot, and would silently retain rows for files that had gone.
  """
  @spec reconcile(Scope.t(), [map()]) :: map()
  def reconcile(%Scope{} = scope, observations) when is_list(observations) do
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
      |> then(&SpecBinding.bind(scope, &1))

    # One statement, and it is both the write and the answer to what moved.
    #
    # `upsert_files/2` updates a conflicting row only where a replaceable column
    # differs and returns exactly what it touched, so `changed` is Postgres's
    # account rather than a comparison this module keeps in step by hand. It
    # used to be the latter: load the whole file table, diff eight fields per
    # observation, upsert the survivors — a ~5,100-row read on every manifest to
    # avoid writing rows that had not moved (4,157 of them on a rejoin where
    # nothing on disk had, which is what exhausted the connection pool —
    # `query_canceled ... while inserting index tuple in relation "files"`,
    # 1aed7edf, 600fbb3a).
    #
    # It also makes hydrating and reconciling one operation. A cold table
    # conflicts with nothing, so every row inserts and every row comes back.
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
              components: project_components(scope, summary),
              moved: moved_roles(summary.changed_entries, summary.removed_records)
            }
          end,
          timeout: @reconcile_timeout_ms
        )

      log_duration(scope, observations, System.monotonic_time(:millisecond) - started, result)
      after_manifest(scope, result.moved)

      Map.delete(result, :moved)
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

  # No environment: the manifest is the harness's own report, and reading a file
  # back from inside its channel asks the process that is waiting on this one.
  defp project_components(scope, summary) do
    changed_paths = Enum.map(summary.changed_entries, & &1.path)
    removed_module_names = ComponentSync.removed_module_names(summary.removed_records)

    {:ok, components} =
      ComponentSync.sync_from_files(scope,
        environment: nil,
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
  defp announce_graph_change(scope, changed_paths, upserted, removed) do
    obs = GraphInputs.observation_id()
    entities = sync_entities(scope, changed_paths, removed)

    Logger.info(
      "[FileSync] announcing a graph change for #{working_copy(scope)} — " <>
        "#{length(changed_paths)} changed, #{upserted} upserted, #{removed} removed",
      obs: obs
    )

    # Recorded here rather than through `GraphInputs.announce/3`, because this
    # site mints its own observation id so the counts above and the mark share
    # one — `announce/3` would mint a second and the log line would name a
    # different burst than the mark it produced.
    # The event as well as the marks, sharing the observation id. Every
    # `file_exists` and `file_valid` requirement — 76 of the graph's 110
    # definitions — is settled from one read by the `:files` profile, and the
    # marks beside it are the fallback for anything without a handler.
    Invalidations.record_event(
      scope.active_project_id,
      "FileSync",
      "files_synced",
      %{},
      entities,
      obs,
      scope.active_working_copy_id
    )

    GraphInputs.changed(scope, obs)
  end

  # Which entities these paths belong to, or nothing when we cannot say.
  #
  # `Files.owners_of_paths/2` resolves a path through its row, so it can only
  # answer for files that still have one. A sync that *removed* files has
  # deleted exactly the rows that would name the components those files belonged
  # to — and a removal is the invalidation that matters most, since it is what
  # turns `spec_file` from true to false. So a sync with any removal names
  # nothing, which records `:unknown` and recomputes everything.
  #
  # Conservative rather than clever: narrowing it means capturing owners before
  # the delete, which is a change to the reconcile path. Until then a removal
  # costs a whole pass and a change costs the entities it touched.
  defp sync_entities(_scope, _changed, removed) when removed > 0, do: []

  defp sync_entities(scope, changed, _removed) do
    Files.owners_of_paths(scope, Enum.map(changed, &path_of/1))
  end

  # The two callers hand this different shapes — `finish_sync/5` has already
  # mapped its entries to paths, `reconcile/2` still holds the entry maps — and
  # ownership is resolved from the row either way rather than from whichever
  # fields an entry happens to carry. The rows were just written, so the
  # database is both available and authoritative; reading `component_id` off an
  # entry would be trusting a shape that differs between the two call sites,
  # and getting it wrong under-invalidates silently.
  defp path_of(path) when is_binary(path), do: path
  defp path_of(%{path: path}), do: path

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

  # -- Lockfile reconcile (577de9bb step 3) --
  #
  # The manifest carries no file content (see `reconcile/2`'s moduledoc), so
  # a changed `:lockfile` entry is only ever a signal to go read it, never
  # the content itself. `maybe_reconcile_lockfile/2` is that signal's
  # handler: cheap to call on every sync (a no-op `Enum.any?` on the
  # already-computed changed set) and safe to call from the periodic sweep
  # with no signal at all, because `reconcile_lockfile/1` re-derives "did it
  # actually change" itself from stored state rather than trusting the
  # caller.
  defp maybe_reconcile_lockfile(scope, changed_entries, env) do
    if Enum.any?(changed_entries, &(&1.role == :lockfile)) do
      reconcile_lockfile(scope, environment: env)
    end

    :ok
  end

  @doc """
  Re-derive a project's dependency set from its main copy's `mix.lock`, if
  the lock has moved since the last time this ran.

  One decision procedure for two callers: `maybe_reconcile_lockfile/2` above
  triggers this the moment a manifest shows `mix.lock` changed, and
  `CodeMySpec.Files.LockfileSweep` calls it on a timer across every project
  regardless of whether anything changed recently. Both get the same
  answer because neither trusts its own trigger — this re-reads the
  project's stored `mix_lock_fingerprint` and the `files` row's own
  fingerprint and compares them itself. That is what makes the sweep a
  correct backstop rather than a second code path: a reconcile that failed
  because the main copy's harness was offline mid-read leaves the stored
  fingerprint stale, and the next tick (sweep or manifest, whichever comes
  first) tries again from the same comparison.
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
    with {:ok, content} <- Environments.read_file(env, "mix.lock"),
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

  # -- Project knowledge reconcile (577de9bb step 5) --

  # The manifest-fed roles whose content the server reads back over the
  # harness: `mix.lock` (step 3) and project knowledge (step 5).
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
           &Environments.read_file(env, &1)
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

  # The stop hook's entry into the same trap `sync/2` was in, and the one the
  # `scannable/1` comment named by name. It ran on every stop, so it is the
  # deletion that actually fired: `0 files scanned … 3937 removed`, four minutes
  # after the fix to `sync/2` went live and while the harness was healthy.
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

    # Two columns, not the whole table. This read exists for the mtime
    # pre-filter below and nothing else now — what changed comes back from the
    # upsert, and what was removed comes back from the delete.
    existing_mtime_map = Files.mtimes_by_path(scope)

    # mtime is the cheap pre-filter, and it is about disk rather than the
    # database: only files that are new or newer get opened and fingerprinted.
    # Whether their content actually moved is Postgres's to decide, so an mtime
    # bump without a content change is a no-op downstream.
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

          # The upsert says what moved. `validated_entries` is everything whose
          # mtime bumped; the rows that come back are the ones whose content,
          # role, ownership or validity actually differs.
          Files.upsert_files(scope, SpecBinding.bind(scope, validated_entries))
      end

    # `changed_paths` reflects files the agent touched this turn (mtime-bumped).
    # Validation drives analyzer selection and `:block_changed` scope from this
    # set — a rewrite of byte-identical impl content still needs the runner
    # analyzers to pick up the corresponding test failures. The fingerprint
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
        # Upsert metadata (role, owners, valid, fingerprint) but NOT mtime —
        # leaves mtime stale so sync_changed still picks the file up during
        # the stop hook pass. Fingerprint updates eagerly per Rule 8 so
        # out-of-band consumers can react to content change in real time.
        #
        # Owner resolution and component-aware validation only run for
        # roles that actually have component/story owners. Doc-corpus files
        # would otherwise trigger expensive `list_components` +
        # `parent_component_id IN (?,?,...)` queries for every individual write.
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

        fingerprint_changed_entries =
          if fingerprint_changed?(entry, existing), do: [entry], else: []

        Files.upsert_file_metadata(scope, entry)

        # Here, not only in the stop hook's pass, because this is the pass that
        # can still see the change.
        #
        # `clear_specs_ready_for_rewritten_specs/3` is keyed on the
        # fingerprint-changed set rather than the mtime-changed one, and that is
        # right: a byte-identical rewrite is not a contract change. But this
        # function updates the fingerprint eagerly (see the comment above the
        # upsert), so by the time `finish_sync_changed/4` runs, the stored
        # fingerprint already matches the file. The entry is in that pass's
        # mtime-changed set and absent from its fingerprint-changed set, so the
        # clear there never sees a spec the watcher already handled.
        #
        # The watcher is what an agent rewriting a story's BDD specs actually
        # fires, so that was every real rewrite. Measured 2026-09-23:
        # `grep '[FileSync] Story' ~/.codemyspec/web.log*` returned nothing on
        # this machine — the clear had never fired once, for any story, since it
        # was written.
        #
        # What that cost: story 947's specs were rewritten to a new contract and
        # its `specs_ready` latch stayed on, so criterion 3159 — deliberately
        # red, because product had decided the feature was to be spec'd before
        # it was built — stayed *enforced*. `Promotion.gate/1` is per-copy, so
        # one enforced red stopped every other story promoting from that
        # checkout, and nothing an agent could call would clear it.
        clear_specs_ready_for_rewritten_specs(scope, fingerprint_changed_entries, [])

        announce_watched_change(scope, fingerprint_changed_entries != [])
        {:ok, %{changed_path: path}}
    end
  end

  # The watcher's path announces too, and this is the one that makes the whole
  # arrangement event-driven rather than polled.
  #
  # `sync_path/3` is what a file event fires — an agent writing a spec, a git
  # checkout landing, an editor saving. It updates the file's fingerprint
  # eagerly, and the comment above says why: "so out-of-band consumers can react
  # to content change in real time". The requirement graph is that consumer, and
  # it was not being told. A file's fingerprint is a graph input; moving one
  # without announcing is the same silence every other writer here was fixed for.
  #
  # That silence is why reads kept re-scanning the filesystem. If the live path
  # says nothing, something has to go looking, so `get_next_requirement` and the
  # stop hook each ran a full `sync/2` to find out what the watcher already
  # knew. With this, the boot scan catches what happened while we were down and
  # events carry it from then on.
  #
  # Only on a real change — a fingerprint that moved, or a file that went away.
  # A watcher fires on writes that change nothing (a save with no edit, a
  # touch), and announcing those would cost a preload each to discover it.
  defp announce_watched_change(_scope, false), do: :ok

  defp announce_watched_change(scope, true),
    do: GraphInputs.announce(scope, "FileSync.watched", [], :this_checkout)

  # Roles that have a meaningful component or story owner. Other
  # roles (project_knowledge, rule, architecture, etc.) are
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
