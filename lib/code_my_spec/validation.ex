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

  The blocking check runs even when no files changed this turn — outstanding
  problems from a prior run still apply.
  """

  require Logger

  alias CodeMySpec.Analysis
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.StaticAnalysis
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
          {:ok, %{changed_files: [map()], analysis: map()}} | {:error, String.t()}
  def validate_stop(%Scope{} = scope, task, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task, opts)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  defp do_validate_stop(%Scope{cwd: nil}, _task, _opts) do
    {:ok, %{changed_files: [], analysis: %{enqueued: [], memoized: []}}}
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

        # An empty attribution set means "this session has not edited
        # anything via PostToolUse yet" — preserve mtime semantics so we
        # don't accidentally suppress blocking problems on a session that
        # simply hasn't fired a tracked edit yet (e.g. direct evaluators
        # that don't go through Claude's Write/Edit pipeline).
        case MapSet.size(attributed) do
          0 -> files
          _ -> Enum.filter(files, &MapSet.member?(attributed, &1.path))
        end

      _ ->
        files
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

    enabled =
      for {analyzer, source} <- @subprocess_analyzers,
          analyzer not in excluded,
          mode_for(config, config_field(analyzer)) != :off,
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

  # Credo mirrors the old pipeline's scoping: `:block_all` sweeps the whole
  # project (a full, memoizable run); other modes run scoped to the turn's
  # changed files (partial — refreshes only those files' problems).
  defp request_for(:credo, changed_files, config) do
    case mode_for(config, :credo) do
      :block_all -> "credo"
      _ -> {"credo", Enum.map(changed_files, & &1.path)}
    end
  end

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
        |> Enum.uniq()
    }

    {blocking, advisory} = partition_problems(problems_by_source, config, scope_context)
    decide(blocking, advisory)
  end

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

        {block, advisory} = apply_mode(problems, mode, scope_fn, scope_context)
        {block_acc ++ block, advisory_acc ++ advisory}
      end)

    {compiler_block ++ configurable_block,
     compiler_advisory ++ configurable_advisory}
  end

  defp partition_compiler(problems, :block), do: {problems, []}

  # Errors always block; only warnings are gated by compile_warnings.
  defp partition_compiler(problems, :dont_block) do
    Enum.split_with(problems, &(&1.severity == :error))
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

  defp decide([], []), do: :ok

  defp decide([], advisory) do
    Logger.warning("[Validation] #{length(advisory)} advisory problem(s) not blocking")
    :ok
  end

  defp decide(blocking, advisory) do
    {:error, Problems.render_stop_response(blocking, advisory)}
  end

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
