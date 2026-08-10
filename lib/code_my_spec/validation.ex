defmodule CodeMySpec.Validation do
  @moduledoc """
  Orchestrates stop hook validation: file sync, in-process validators, and
  the blocking decision — with subprocess analyzers (compile, credo, tests,
  spex) enqueued as background `Analysis` runs instead of executed inline.

  The stop decision is made immediately from persisted Problems; background
  runs reconcile new problems on their own schedule (surviving the hook's
  HTTP timeout) and apply to the next stop. `Analysis`'s run ledger skips
  any analyzer whose inputs haven't changed since its last completed run.

  The blocking decision consults `ProjectConfiguration` modes per source:

  - `:off` — source never blocks (matches `resolve_analyzers` filtering)
  - `:block_all` — every problem from this source blocks
  - `:block_changed` — only problems on files/components changed during the
    task block; others are advisory
  - `:dont_block` — problems are persisted but never block

  Spex is filtered per-story before the mode applies: a spex failure only
  counts toward blocking when the owning story's `specs_ready` latch is
  set. Failures on stories still mid-build are advisory regardless of
  mode, which is what makes enabling spex project-wide survivable.

  The blocking check runs even when no files changed this turn — outstanding
  problems from a prior run still apply.
  """

  require Logger

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Analysis
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  # Analyzer atoms that execute as mix subprocesses → their Analysis source.
  # Everything else in a resolved analyzer set runs in-process (fast) inside
  # this request.
  @subprocess_analyzers %{credo: "credo", exunit_stale: "exunit", spex_stale: "spex"}

  # Configurable source → {ProjectConfiguration field, scope predicate for
  # :block_changed mode}.
  @configurable_sources %{
    "credo" => {:credo, :by_file_path},
    "exunit" => {:exunit, :by_component_id},
    "spex" => {:spex, :by_file_path},
    "spec_validation" => {:spec_validation, :by_file_path},
    "qa_validation" => {:qa_validation, :by_file_path}
  }

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files: [File.t()]}}` on success, or
  `{:error, reason}` if compilation fails or the blocking check rejects.

  ## Options

  - `:compile_output_file` - pre-recorded diagnostics JSONL (test-only)
  - `:credo_output_file` - pre-recorded credo JSON (test-only)
  - `:exunit_output_file` - pre-recorded ExUnit JSON (test-only)
  - `:spex_output_file` - pre-recorded spex JSONL (test-only)
  - `:session_id` - external session id; when present, the changed-file
    set is intersected with PostToolUse-attributed edits for this
    `(session_id, agent_id)`. Problems on files attributed elsewhere
    are excluded from the block decision.
  - `:agent_id` - sub-agent id; nil means the main agent. Combined with
    `:session_id` for the FileEdits attribution lookup.
  - `:await` - test-only; block until enqueued background runs finish before
    the blocking check, restoring synchronous semantics for deterministic
    specs. The stop hook never passes this.

  Set by `StopController` from the `test_output_files` request param so
  cassette-backed specs can drive the pipeline with known outputs without
  relying on `System.cmd` side effects.
  """
  @spec validate_stop(Scope.t(), map() | nil, keyword()) ::
          {:ok, %{changed_files: [map()], analysis: map()}}
          | {:error, String.t(), String.t() | nil}
  def validate_stop(%Scope{} = scope, task, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task, opts)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  # No project bound yet — a stop hook firing before `init_project`. There is
  # nothing to check and nothing to check it against.
  defp do_validate_stop(%Scope{active_project_id: nil}, _task, _opts) do
    {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
  end

  # No working copy on this machine. Until the light harness that is a project
  # nobody can look at, and this clause answered `{:ok, …}` — no analysis, no
  # blocking check, an unconditional allow. That was right while the only way to
  # reach it was a caller with no project on disk anywhere. It stopped being
  # right the moment a harness started holding the disk on the other end of a
  # channel, because the stop hook then arrived here on every single agent turn
  # and got an answer computed from nothing.
  #
  # So the question is no longer "is there a working copy here" but "is there
  # one anywhere I can reach". A harness holding this project is the yes.
  defp do_validate_stop(%Scope{cwd: nil} = scope, task, opts) do
    case Analysis.remote_executor(scope) do
      {:ok, _harness} ->
        remote_validate_stop(scope, task, opts)

      :none ->
        {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
    end
  end

  defp do_validate_stop(%Scope{cwd: cwd} = scope, task, opts) do
    {:ok, sync_result} = FileSync.sync_changed(scope, base_dir: cwd)

    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: sync_result.changed_paths
    )

    changed_files =
      scope
      |> resolve_changed_files(task, sync_result)
      |> filter_by_session_attribution(cwd, opts)

    config = Configurations.get_or_create(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    if Keyword.get(opts, :await, false), do: Analysis.await_all(scope)

    with :ok <- check_blocking_problems(scope, changed_files, config) do
      {:ok, %{changed_files: changed_files, analysis: analysis}}
    end
  end

  # The same pipeline, minus the two steps that need a disk here.
  #
  # `FileSync.sync_changed/2` is skipped because the harness has already done
  # its equivalent: it scanned its own working copy and reconciled the whole
  # manifest over the channel, so the File rows this reads are current with the
  # disk by a different route. `StaticAnalysis.run_analyzers/5` — the in-process
  # validators — is skipped because those read file contents, which never cross
  # the wire.
  #
  # Everything that is left is database work and runs unchanged: the same
  # changed-file scoping, the same configuration modes, the same
  # `Analysis.ensure_stale_runs/3` (dispatched to the harness rather than to a
  # local queue), and the same blocking check. The point is that the *decision*
  # is identical; only where the tools ran differs.
  defp remote_validate_stop(scope, task, opts) do
    changed_files = remote_changed_files(scope, task, opts)
    config = Configurations.get_or_create(scope)

    analysis = run_pipeline(scope, task, changed_files, config, opts)

    if Keyword.get(opts, :await, false), do: Analysis.await_all(scope)

    with :ok <- check_blocking_problems(scope, changed_files, config) do
      {:ok, %{changed_files: changed_files, analysis: analysis}}
    end
  end

  # With a task, the same answer the local path gives: every File row whose
  # mtime moved since the task started. mtime comes off the harness's manifest,
  # so this needs no disk.
  #
  # Narrowed by attribution for the same reason the local path is, and it was
  # not: mtime cannot tell "the agent wrote this" from "git wrote this", and a
  # rebase rewrites mtimes on everything it touches. The window is
  # `started_at`, so the longer a task stays open the more of the repo it
  # swallows — a task blocked upstream for days collects the lot.
  #
  # `cwd` is nil here by construction: this path exists precisely because the
  # disk is on the other end of a channel. The harness sends its edit paths
  # project-relative, so `relativize/2` has nothing to strip and passes them
  # through.
  defp remote_changed_files(scope, %{started_at: started_at} = task, opts)
       when not is_nil(started_at) do
    changed_files_for_task(scope, task, opts)
  end

  # Without a task, the local path uses the paths its own scan found dirty.
  # There is no scan here, so the equivalent is what this session actually
  # wrote — PostToolUse records every Write/Edit, and the harness sends those
  # paths project-relative precisely so they resolve to File rows here.
  #
  # Empty means the agent wrote nothing this session, which is a quiet stop and
  # is treated as one. It does not mean "could not tell": a session that edited
  # something has those edits recorded, and a project with no harness never
  # reaches this function at all.
  defp remote_changed_files(scope, _task, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        session_id
        |> attributed_paths(Keyword.get(opts, :agent_id))
        |> then(&Files.get_by_paths(scope, &1))

      _ ->
        []
    end
  end

  @doc false
  # Public only so the property that matters can be asserted directly: mtime
  # moves, git state does not, and the blocking set follows what the session
  # recorded rather than the clock. Same reasoning as `blocking_key/1`.
  def changed_files_for_task(scope, %{started_at: started_at}, opts) do
    scope
    |> Files.changed_since(started_at)
    |> filter_by_session_attribution(nil, opts)
  end

  # When a session is in play, narrow the changed-file set to files this
  # session+agent actually wrote (via PostToolUse). The mtime-based
  # `Files.changed_since` view picks up every dirty file on disk; without
  # this filter a parallel session's writes leak into the current stop's
  # block decision. No session → no filter (preserves behaviour for direct
  # callers that don't run inside the hook lifecycle).
  defp filter_by_session_attribution(files, cwd, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        # PostToolUse stores whatever Claude passed — typically absolute
        # paths like `/Users/.../project/lib/foo.ex`. Files.path is
        # project-relative (`lib/foo.ex`). Normalize attributed paths to
        # relative against cwd before comparison or every session with a
        # tracked edit would land empty.
        attributed =
          session_id
          |> attributed_paths(Keyword.get(opts, :agent_id))
          |> Enum.map(&relativize(&1, cwd))
          |> MapSet.new()

        narrow_to_attributed(files, attributed, session_id)

      _ ->
        files
    end
  end

  # How many mtime-dirty files stop looking like a turn and start looking like
  # a rebase.
  #
  # A number rather than a rule, because the two cases are only distinguishable
  # by size from here: a session writing through something other than
  # Write/Edit — a spex, a direct evaluator, the harness — records no
  # attribution and is indistinguishable from a session whose attribution
  # broke. What separates them in practice is scale. The reported incident had
  # 232 dirty files against 6 real edits; a spex writes one or two.
  #
  # Deliberately generous. Over this line the set is discarded, and discarding
  # a real turn's work is the expensive mistake — an agent's own violations
  # would go unblocked. Under it the mtime set is kept, which is what the
  # behaviour was before and is wrong only in the narrow case of a small rebase
  # with no attribution.
  @rebase_sized 25

  # A session that recorded no edits wrote nothing, and the honest changed-file
  # set for that is empty.
  #
  # This returned `files` — every mtime-dirty file — on the reasoning that a
  # direct evaluator bypassing Write/Edit should not have its problems
  # suppressed. The cost of that reading is what it does when attribution goes
  # empty for a reason that is not "nothing was written": a session restart, or
  # a recorded path shape that does not match `Files.path`. Then the one filter
  # that narrows the set instead removes itself, and a stop blocks on every
  # dirty file in the tree.
  #
  # That happened. `git rebase` rewrites mtimes on everything it touches, so a
  # session that rebased onto a busy main inherited 232 mtime-dirty files, and
  # the hook blocked five times running on 49 credo violations in spex belonging
  # to three other stories. The only compliant response was to edit code the
  # agent did not own, which is a gate that cannot be satisfied honestly.
  #
  # Failing closed inverts the risk into the recoverable direction: a missed
  # violation is caught by the next analysis run and stays on the Problems page,
  # while a repo-wide block teaches everyone to route around the gate. Loudly,
  # because "the agent wrote nothing" and "attribution is broken" are different
  # and only the log can tell them apart.
  defp narrow_to_attributed(files, attributed, session_id) do
    case {MapSet.size(attributed), length(files)} do
      {0, dirty} when dirty > @rebase_sized ->
        Logger.warning(
          "[Validation] session #{session_id} recorded no edits, but #{dirty} file(s) " <>
            "look changed — more than a turn writes. Treating the turn as having " <>
            "written nothing rather than blocking on all of them; if the agent did " <>
            "edit files, PostToolUse attribution is not reaching this project's " <>
            "File paths."
        )

        []

      {0, _dirty} ->
        files

      _ ->
        Enum.filter(files, &MapSet.member?(attributed, &1.path))
    end
  end

  defp relativize(path, cwd) when is_binary(path) and is_binary(cwd) do
    cond do
      Path.type(path) == :relative -> path
      String.starts_with?(path, cwd <> "/") -> Path.relative_to(path, cwd)
      true -> Path.relative_to(path, cwd)
    end
  end

  defp relativize(path, _cwd), do: path

  defp attributed_paths(session_id, nil), do: FileEdits.get_edited_files(session_id)

  defp attributed_paths(session_id, agent_id) when is_binary(agent_id),
    do: FileEdits.get_edited_files_by_agent(session_id, agent_id)

  # In-process validators run synchronously (they're milliseconds); the four
  # subprocess sources go through Analysis — enqueued in the background,
  # memoized against the run ledger when inputs haven't changed. Returns the
  # `%{enqueued: [...], memoized: [...]}` summary.
  #
  # No changed files → stay quiet (criterion 5097): only re-enqueue sources
  # whose latest run failed (crash/timeout/superseded recovery), via
  # `only_failed`.
  defp run_pipeline(scope, task, [], config, opts) do
    excluded = StaticAnalysis.task_excluded_analyzers(task)

    # `:spex_stale` runs whatever its mode: the specs-passing gate depends
    # on a current spex run existing, and the mode only governs blocking.
    # See the note on `@config_gated_analyzers` in StaticAnalysis.Pipeline.
    enabled =
      for {analyzer, source} <- @subprocess_analyzers,
          analyzer not in excluded,
          analyzer == :spex_stale or mode_for(config, config_field(analyzer)) != :off,
          do: source

    Analysis.ensure_stale_runs(
      scope,
      Enum.uniq(["compiler" | enabled]),
      Keyword.put(opts, :only_failed, true)
    )
  end

  defp run_pipeline(scope, task, changed_files, config, opts) do
    log_changed_files(changed_files)

    analyzers = StaticAnalysis.resolve_analyzers(task, changed_files, config)

    {subprocess, in_process} =
      Enum.split_with(analyzers, &Map.has_key?(@subprocess_analyzers, &1))

    StaticAnalysis.run_analyzers(scope, in_process, changed_files, config, opts)

    requests =
      ["compiler" | Enum.map(subprocess, &request_for(&1, changed_files, config))]
      |> Enum.uniq()

    Analysis.ensure_stale_runs(scope, requests, opts)
  end

  # Every source, credo included, scans the whole project. The config mode
  # decides whether credo *blocks*; it no longer decides what credo looks at.
  #
  # `:block_changed` still blocks only on violations in the turn's changed
  # files — that filtering lives in `apply_mode/4` at decision time. What
  # changes is that violations elsewhere are now persisted as advisory and
  # visible on the Problems page instead of never being looked for.
  defp request_for(analyzer, _changed_files, _config),
    do: Map.fetch!(@subprocess_analyzers, analyzer)

  defp config_field(:credo), do: :credo
  defp config_field(:exunit_stale), do: :exunit
  defp config_field(:spex_stale), do: :spex

  defp resolve_changed_files(scope, %{started_at: started_at}, _sync_result)
       when not is_nil(started_at) do
    Files.changed_since(scope, started_at)
  end

  defp resolve_changed_files(scope, _task, sync_result) do
    case sync_result.changed_paths do
      [] -> []
      paths -> Files.get_by_paths(scope, paths)
    end
  end

  defp check_blocking_problems(scope, changed_files, config) do
    sources = active_blocking_sources(config)

    # Problems are an eventually consistent projection: block on what is
    # recorded, report staleness, let the run this kicks off replace it.
    problems_by_source =
      scope
      |> Problems.list_project_problems(sources: sources)
      |> Enum.group_by(& &1.source)

    scope_context = %{
      changed_file_paths: Enum.map(changed_files, & &1.path),
      changed_component_ids:
        changed_files
        |> Enum.map(& &1.component_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      specs_ready_story_ids: specs_ready_story_ids(scope),
      criterion_story_ids: AcceptanceCriteria.spec_path_story_ids(scope)
    }

    # One pass over the file ledger for every source, rather than one per
    # source. See `Analysis.fresh_sources/2` — the answer is identical.
    sources_with_problems = Map.keys(problems_by_source)
    fresh = Analysis.fresh_sources(scope, sources_with_problems)
    stale_sources = Enum.reject(sources_with_problems, &MapSet.member?(fresh, &1))

    {blocking, advisory} = partition_problems(problems_by_source, config, scope_context)

    decide(blocking, advisory, stale_sources,
      last_ran: last_ran(scope, stale_sources),
      # Whether a rerun is actually running, as opposed to how old the newest
      # result is. The message used to assert the first from the second and got
      # it wrong in both directions.
      in_flight: Analysis.in_flight(scope)
    )
  end

  # When each stale source last finished. "Stale" alone cannot tell "a rerun is
  # coming" from "no rerun can land", and those need opposite responses: wait,
  # or stop editing and report the analyzer. A source that last ran two minutes
  # ago is mid-cycle; one that last ran forty minutes ago, across several
  # stops, is not coming back on its own.
  defp last_ran(_scope, []), do: %{}

  defp last_ran(scope, sources) do
    status = Analysis.status(scope)

    Map.new(sources, fn source ->
      {source, get_in(status, [source, :run]) |> finished_at()}
    end)
  end

  defp finished_at(%{finished_at: %DateTime{} = at}), do: at
  defp finished_at(_), do: nil

  defp active_blocking_sources(config) do
    configurable =
      for {source, {field, _scope_fn}} <- @configurable_sources,
          mode_for(config, field) != :off,
          do: source

    ["compiler" | configurable]
  end

  # Rows predating a new analyzer_mode column have NULL for that field since
  # schema `default:` only applies on struct build, not on DB load. Fall back
  # to the schema default so the blocking decision stays consistent.
  defp mode_for(config, field) do
    Map.get(config, field) || Map.fetch!(%ProjectConfiguration{}, field)
  end

  defp partition_problems(problems_by_source, config, scope_context) do
    {compiler_block, compiler_advisory} =
      partition_compiler(Map.get(problems_by_source, "compiler", []), config.compile_warnings)

    {configurable_block, configurable_advisory} =
      Enum.reduce(@configurable_sources, {[], []}, fn {source, {field, scope_fn}},
                                                      {block_acc, advisory_acc} ->
        mode = mode_for(config, field)
        problems = Map.get(problems_by_source, source, [])

        {enforced, unenforced} = split_by_story_enforcement(source, problems, scope_context)

        {block, advisory} = apply_mode(enforced, mode, scope_fn, scope_context)
        {block_acc ++ block, advisory_acc ++ advisory ++ unenforced}
      end)

    {compiler_block ++ configurable_block, compiler_advisory ++ configurable_advisory}
  end

  defp partition_compiler(problems, :block), do: {problems, []}

  # Errors always block; only warnings are gated by compile_warnings.
  defp partition_compiler(problems, :dont_block) do
    Enum.split_with(problems, &(&1.severity == :error))
  end

  # Spex enforcement is per-story, and it runs BEFORE the configured mode
  # rather than as another mode. A story that has never gone green is
  # *supposed* to be red — its specs are the contract driving the
  # implementation that hasn't been written yet. Blocking on that is what
  # kept `ProjectConfiguration.spex` pinned at `:off`.
  #
  # Demoted problems stay advisory rather than being dropped: the failure
  # is still real and still belongs on the Problems page, it just isn't
  # the agent's problem yet.
  #
  # Every other source is story-agnostic and passes through untouched.
  # The criterion says which story it belongs to. The filename does not.
  #
  # This read the leading number out of `test/spex/<n>_.../` and treated it as a
  # story id. Those numbers are directory names and have drifted from the ids:
  # measured on this project, `811_user_sees_the_agents_task_queue_at_a_glance`
  # derives 811 — a real story, "Onboarding lives at /app", `specs_ready` false
  # — while the story with that title is 862, `specs_ready` true. So a latched
  # story gated nothing (no path derives 862) and an unlatched one gated spex
  # that were not its own.
  #
  # Both wrong answers are silent, because a number that resolves to *a* story
  # looks exactly like one that resolves to the right story. A missing story
  # would have hit the `nil` branch and been loud.
  #
  # `criteria.spec_path` is the recorded answer — `claim_spec_paths/2` writes it
  # when a spex file is created, which is why it survives a rename. 22 of this
  # project's 25 spex problems join on it exactly.
  #
  # The filename parse stays as the fallback for a spex no criterion claims.
  # There is no right answer for an orphan, and changing what happens to those
  # is a separate decision from fixing the ones that do have an answer.
  defp split_by_story_enforcement("spex", problems, ctx) do
    %{specs_ready_story_ids: ready_ids, criterion_story_ids: by_path} = ctx

    Enum.split_with(problems, fn problem ->
      case Map.get(by_path, problem.file_path) || Parser.derive_story_id(problem.file_path) do
        nil -> true
        story_id -> MapSet.member?(ready_ids, story_id)
      end
    end)
  end

  defp split_by_story_enforcement(_source, problems, _ctx), do: {problems, []}

  defp specs_ready_story_ids(scope) do
    scope
    |> Stories.list_specs_ready_story_ids()
    |> MapSet.new()
  end

  defp apply_mode(_problems, :off, _scope_fn, _ctx), do: {[], []}
  defp apply_mode(problems, :block_all, _scope_fn, _ctx), do: {problems, []}
  defp apply_mode(problems, :dont_block, _scope_fn, _ctx), do: {[], problems}

  defp apply_mode(problems, :block_changed, scope_fn, ctx) do
    Enum.split_with(problems, in_scope_fn(scope_fn, ctx))
  end

  defp in_scope_fn(:by_file_path, %{changed_file_paths: paths}) do
    &(&1.file_path in paths)
  end

  defp in_scope_fn(:by_component_id, %{changed_component_ids: ids}) do
    &(&1.component_id in ids)
  end

  defp decide([], [], _stale, _opts), do: :ok

  defp decide([], advisory, _stale, _opts) do
    Logger.warning("[Validation] #{length(advisory)} advisory problem(s) not blocking")
    :ok
  end

  defp decide(blocking, advisory, stale_sources, opts) do
    if stale_sources != [] do
      Logger.info("[Validation] blocking on stale sources: #{Enum.join(stale_sources, ", ")}")
    end

    reason =
      Problems.render_stop_response(
        blocking,
        advisory,
        Keyword.put(opts, :stale_sources, stale_sources)
      )

    {:error, reason, blocking_key(blocking)}
  end

  # What is blocking, as something that can be compared across stops.
  #
  # Deliberately not the rendered reason. R8's repeat detection hashes the text
  # it is given, and this text carries relative ages — "stale, last ran 3
  # minutes ago" — which change on every stop. Hashing it would produce a new
  # value each time and the streak would never build, so the escape would be
  # silently inert in exactly the case that needs it most: an analyzer lagging
  # while the same findings block turn after turn.
  #
  # The findings themselves are stable. A fixed problem, a new one, or a moved
  # line all change this; waiting does not.
  @doc false
  # Public only so the property that matters can be asserted directly: stable
  # while a source ages, different the moment a finding changes.
  def blocking_key([]), do: nil

  def blocking_key(blocking) do
    blocking
    |> Enum.map(&{&1.source, &1.file_path, &1.line, &1.message})
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
