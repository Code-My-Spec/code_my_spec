defmodule CodeMySpec.Validation do
  @moduledoc """
  Orchestrates stop hook validation: file sync, compilation, static analysis,
  tests, and the final blocking decision.

  Runs analyzers and writes results to DB. The blocking decision consults
  `ProjectConfiguration` modes per source:

  - `:off` — source never blocks (matches `resolve_analyzers` filtering)
  - `:block_all` — every problem from this source blocks
  - `:block_changed` — only problems on files/components changed during the
    task block; others are advisory
  - `:dont_block` — problems are persisted but never block

  The blocking check runs even when no files changed this turn — outstanding
  problems from a prior run still apply.
  """

  require Logger

  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Tests
  alias CodeMySpec.Users.Scope

  @runner_analyzers [:exunit_stale, :spex_stale]

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

  Set by `StopController` from the `test_output_files` request param so
  cassette-backed specs can drive the pipeline with known outputs without
  relying on `System.cmd` side effects.
  """
  @spec validate_stop(Scope.t(), map() | nil, keyword()) ::
          {:ok, %{changed_files: [map()]}} | {:error, String.t()}
  def validate_stop(%Scope{} = scope, task, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task, opts)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  defp do_validate_stop(%Scope{cwd: nil}, _task, _opts) do
    {:ok, %{changed_files: []}}
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

    with :ok <- run_pipeline(scope, task, changed_files, config, opts),
         :ok <- check_blocking_problems(scope, changed_files, config) do
      {:ok, %{changed_files: changed_files}}
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

  defp run_pipeline(scope, task, changed_files, config, opts) do
    forced = forced_runners(scope, config)

    cond do
      changed_files != [] ->
        log_changed_files(changed_files)
        run_full_pipeline(scope, task, changed_files, config, opts, forced)

      forced != [] ->
        Logger.info(
          "[Validation] No changed files; reconciling persisted problems via #{inspect(forced)}"
        )

        run_runner_analyzers(scope, forced, opts)
        :ok

      true ->
        Logger.info("[Validation] No changed files, skipping pipeline")
        :ok
    end
  end

  defp run_full_pipeline(scope, task, changed_files, config, opts, forced) do
    with :ok <- StaticAnalysis.compile(scope, opts) do
      analyzers = StaticAnalysis.resolve_analyzers(task, changed_files, config)
      {runners, static} = Enum.split_with(analyzers, &(&1 in @runner_analyzers))
      runners = Enum.uniq(runners ++ forced)
      StaticAnalysis.run_analyzers(scope, static, changed_files, config, opts)
      run_runner_analyzers(scope, runners, opts)
      :ok
    end
  end

  # `mix spex --stale` keeps previously-failed specs in its stale set (via
  # `Mix.Compilers.Test`), so re-running it reconciles persisted spex problems
  # even on turns that touched no implementation or bdd_spec files. Without
  # this, stale failures linger until something in those roles changes.
  defp forced_runners(scope, config) do
    if mode_for(config, :spex) != :off and persisted_problems?(scope, "spex") do
      [:spex_stale]
    else
      []
    end
  end

  defp persisted_problems?(scope, source) do
    scope
    |> Problems.list_project_problems(source: source)
    |> Enum.any?()
  end

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

  defp run_runner_analyzers(scope, analyzers, opts) do
    Enum.each(analyzers, &run_runner_analyzer(scope, &1, opts))
  end

  defp run_runner_analyzer(scope, :exunit_stale, opts) do
    exec_opts = [project_root: scope.cwd] |> maybe_put_output_file(opts, :exunit_output_file)

    run_and_persist(scope, "mix test --stale", "exunit", fn ->
      case Tests.execute(["--stale"], exec_opts) do
        {:ok, test_run} -> {:ok, test_run.failures, &test_failure_to_problem/1}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp run_runner_analyzer(scope, :spex_stale, opts) do
    exec_opts = [project_root: scope.cwd] |> maybe_put_output_file(opts, :spex_output_file)

    run_and_persist(scope, "mix spex --stale", "spex", fn ->
      case Spex.execute(["--stale"], exec_opts) do
        {:ok, failures, _exit_code} -> {:ok, failures, &spex_failure_to_problem/1}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp maybe_put_output_file(exec_opts, opts, key) do
    case Keyword.get(opts, key) do
      nil -> exec_opts
      path -> Keyword.put(exec_opts, :output_file, path)
    end
  end

  defp run_and_persist(scope, label, source, runner) do
    Logger.info("[Validation] Running #{label}")
    start = System.monotonic_time(:millisecond)

    case runner.() do
      {:ok, failures, to_problem} ->
        problems =
          failures
          |> Enum.map(to_problem)
          |> Enum.map(&%{&1 | project_id: scope.active_project_id, source: source})

        Problems.clear_problems_for_source(scope, [source: source], :all)
        Problems.create_problems(scope, problems)

        ms = System.monotonic_time(:millisecond) - start
        Logger.info("[Validation] #{label}: #{length(problems)} failure(s) (#{ms}ms)")

      {:error, reason} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.warning("[Validation] #{label} failed (#{ms}ms): #{inspect(reason)}")
    end
  end

  defp test_failure_to_problem(result), do: ProblemConverter.from_test_failure(result.error)

  defp spex_failure_to_problem(failure) do
    ProblemConverter.from_test_failure(%{
      file: failure.error && failure.error.file,
      line: failure.error && failure.error.line,
      test: "#{failure.spex} — #{failure.scenario}",
      message: (failure.error && failure.error.message) || "Spex scenario failed"
    })
  end

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
