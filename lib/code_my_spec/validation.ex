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
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.ProblemConverter
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Tests
  alias CodeMySpec.Users.Scope

  @runner_analyzers [:exunit_stale, :spex_stale]

  # Sources that always block — no config knob, these are cheap correctness
  # gates (compiler errors, spec/QA validation).
  @always_blocking_sources ["spec_validation", "qa_validation"]

  # Configurable sources → the ProjectConfiguration field that gates them +
  # the "in scope" predicate used for `:block_changed` mode.
  @configurable_sources %{
    "credo" => {:credo, :by_file_path},
    "exunit" => {:exunit, :by_component_id},
    "spex" => {:spex, :by_file_path}
  }

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files: [File.t()]}}` on success, or
  `{:error, reason}` if compilation fails or the blocking check rejects.
  """
  @spec validate_stop(Scope.t(), map() | nil, keyword()) ::
          {:ok, %{changed_files: [map()]}} | {:error, String.t()}
  def validate_stop(%Scope{} = scope, task, _opts \\ []) do
    start = System.monotonic_time(:millisecond)

    result = do_validate_stop(scope, task)

    elapsed = System.monotonic_time(:millisecond) - start
    Logger.info("[Validation] validate_stop completed in #{elapsed}ms")

    result
  end

  defp do_validate_stop(%Scope{cwd: nil}, _task) do
    {:ok, %{changed_files: []}}
  end

  defp do_validate_stop(%Scope{cwd: cwd} = scope, task) do
    {:ok, sync_result} = FileSync.sync_changed(scope, base_dir: cwd)

    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: sync_result.changed_paths
    )

    changed_files = resolve_changed_files(scope, task, sync_result)
    config = Configurations.get_or_create(scope)

    with :ok <- run_pipeline(scope, task, changed_files, config),
         :ok <- check_blocking_problems(scope, changed_files, config) do
      {:ok, %{changed_files: changed_files}}
    end
  end

  defp run_pipeline(_scope, _task, [], _config) do
    Logger.info("[Validation] No changed files, skipping pipeline")
    :ok
  end

  defp run_pipeline(scope, task, changed_files, config) do
    log_changed_files(changed_files)
    changed_file_paths = Enum.map(changed_files, & &1.path)

    with :ok <- StaticAnalysis.compile(scope, changed_file_paths) do
      analyzers = StaticAnalysis.resolve_analyzers(task, changed_files, config)
      {runners, static} = Enum.split_with(analyzers, &(&1 in @runner_analyzers))
      StaticAnalysis.run_analyzers(scope, static, changed_files)
      run_runner_analyzers(scope, runners)
      :ok
    end
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

  # -- Blocking problem check --

  defp check_blocking_problems(scope, changed_files, config) do
    sources = active_blocking_sources(config)

    problems_by_source =
      scope
      |> Problems.list_project_problems(sources: sources)
      |> Enum.group_by(& &1.source)

    changed_file_paths = Enum.map(changed_files, & &1.path)

    changed_component_ids =
      changed_files
      |> Enum.map(& &1.component_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    scope_context = %{
      changed_file_paths: changed_file_paths,
      changed_component_ids: changed_component_ids
    }

    {blocking, advisory} = partition_problems(problems_by_source, config, scope_context)

    decide(blocking, advisory)
  end

  defp active_blocking_sources(config) do
    configurable =
      Enum.flat_map(@configurable_sources, fn {source, {field, _scope_fn}} ->
        if Map.get(config, field) == :off, do: [], else: [source]
      end)

    ["compiler" | @always_blocking_sources] ++ configurable
  end

  defp partition_problems(problems_by_source, config, scope_context) do
    {compiler_block, compiler_advisory} =
      partition_compiler(Map.get(problems_by_source, "compiler", []), config.compile_warnings)

    always_block =
      Enum.flat_map(@always_blocking_sources, &Map.get(problems_by_source, &1, []))

    {configurable_block, configurable_advisory} =
      Enum.reduce(@configurable_sources, {[], []}, fn {source, {field, scope_fn}},
                                                      {block_acc, advisory_acc} ->
        mode = Map.get(config, field)
        problems = Map.get(problems_by_source, source, [])

        {block, advisory} = apply_mode(problems, mode, scope_fn, scope_context)
        {block_acc ++ block, advisory_acc ++ advisory}
      end)

    blocking = compiler_block ++ always_block ++ configurable_block
    advisory = compiler_advisory ++ configurable_advisory

    {blocking, advisory}
  end

  defp partition_compiler(problems, :block), do: {problems, []}

  defp partition_compiler(problems, :dont_block) do
    # Errors always block; only warnings are gated by compile_warnings.
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
    advisory_section =
      if advisory != [] do
        "\n\nAdditional problems on untouched scope (not blocking):\n\n#{format_problems(advisory)}"
      else
        ""
      end

    {:error, "Fix these problems before stopping:\n\n#{format_problems(blocking)}#{advisory_section}"}
  end

  defp format_problems(problems) do
    problems
    |> Enum.group_by(& &1.source)
    |> Enum.map_join("\n", &format_problem_group/1)
  end

  defp format_problem_group({source, items}) do
    details =
      items
      |> Enum.take(10)
      |> Enum.map_join("\n", fn p -> "  - #{p.file_path}:#{p.line}: #{p.message}" end)

    truncated = if length(items) > 10, do: "\n  ... and #{length(items) - 10} more", else: ""
    "#{source} (#{length(items)}):\n#{details}#{truncated}"
  end

  # -- Runner analyzers (test/spex subprocesses) --

  defp run_runner_analyzers(scope, analyzers) do
    Enum.each(analyzers, &run_runner_analyzer(scope, &1))
  end

  defp run_runner_analyzer(scope, :exunit_stale) do
    run_and_persist(scope, "mix test --stale", "exunit", fn ->
      case Tests.execute(["--stale"], project_root: scope.cwd) do
        {:ok, test_run} -> {:ok, test_run.failures, &test_failure_to_problem/1}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp run_runner_analyzer(scope, :spex_stale) do
    run_and_persist(scope, "mix spex --stale", "spex", fn ->
      case Spex.execute(["--stale"], project_root: scope.cwd) do
        {:ok, failures, _exit_code} -> {:ok, failures, &spex_failure_to_problem/1}
        {:error, reason} -> {:error, reason}
      end
    end)
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
        if problems != [], do: Problems.create_problems(scope, problems)

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

  # -- Logging --

  defp log_changed_files(changed_files) do
    summary =
      changed_files
      |> Enum.group_by(& &1.role)
      |> Enum.map_join(", ", fn {role, files} -> "#{role}(#{length(files)})" end)

    Logger.info("[Validation] Changed files: #{summary}")
  end
end
