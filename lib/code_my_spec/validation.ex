defmodule CodeMySpec.Validation do
  @moduledoc """
  Orchestrates stop hook validation: file sync, compilation, static analysis, and tests.

  Runs analyzers and writes results to DB. Does NOT decide pass/fail — that's
  `TaskEvaluator`'s job (pure DB read).

  ## Flow

  1. Incremental file sync (`sync_changed`)
  2. Query changed files since task start
  3. Early return if no changes
  4. Compile (blocks on errors)
  5. Resolve analyzers (role-derived + task-declared)
  6. Split analyzers: static ones run through StaticAnalysis, the runner
     analyzers (`:exunit_stale`, `:spex_stale`) run here as subprocesses
  7. Return changed files
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

  @doc """
  Run the full validation pipeline for a stop hook.

  Returns `{:ok, %{changed_files: [File.t()]}}` on success, or
  `{:error, reason}` if compilation fails.
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
    run_analysis(scope, task, changed_files)
  end

  defp run_analysis(_scope, _task, []) do
    Logger.info("[Validation] No changed files, skipping all analysis")
    {:ok, %{changed_files: []}}
  end

  defp run_analysis(scope, task, changed_files) do
    changed_file_paths = Enum.map(changed_files, & &1.path)
    log_changed_files(changed_files)
    config = Configurations.get_or_create(scope)

    with :ok <- StaticAnalysis.compile(scope, changed_file_paths),
         analyzers = StaticAnalysis.resolve_analyzers(task, changed_files, config),
         {runners, static} = Enum.split_with(analyzers, &(&1 in @runner_analyzers)),
         _ = StaticAnalysis.run_analyzers(scope, static, changed_files),
         _ = run_runner_analyzers(scope, runners),
         :ok <- check_blocking_problems(scope, changed_files) do
      {:ok, %{changed_files: changed_files}}
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

  defp check_blocking_problems(scope, changed_files) do
    changed_file_paths = Enum.map(changed_files, & &1.path)

    changed_component_ids =
      changed_files
      |> Enum.map(& &1.component_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    problems_by_source =
      scope
      |> Problems.list_project_problems(sources: ["compiler", "credo", "exunit"])
      |> Enum.group_by(& &1.source)

    compiler_problems = Map.get(problems_by_source, "compiler", [])

    credo_problems =
      problems_by_source
      |> Map.get("credo", [])
      |> Enum.filter(&(&1.file_path in changed_file_paths))

    {blocking_tests, advisory_tests} =
      problems_by_source
      |> Map.get("exunit", [])
      |> Enum.split_with(&(&1.component_id in changed_component_ids))

    blocking = compiler_problems ++ credo_problems ++ blocking_tests

    advisory_section =
      if advisory_tests != [] do
        "\n\nAdditional test failures on other components (not blocking):\n\n#{format_problems(advisory_tests)}"
      else
        ""
      end

    case blocking do
      [] ->
        if advisory_tests != [] do
          Logger.warning(
            "[Validation] #{length(advisory_tests)} test failure(s) on other components"
          )
        end

        :ok

      _ ->
        {:error,
         "Fix these problems before stopping:\n\n#{format_problems(blocking)}#{advisory_section}"}
    end
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
