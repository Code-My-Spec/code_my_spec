defmodule CodeMySpec.Validation do
  @moduledoc """
  Validates files edited during Claude Code sessions.

  Three-phase validation pipeline:
  - Phase 1a: Static analysis (compiler, credo, sobelow) on dirty components
  - Phase 1b: Tests via `mix test --stale` (Elixir's manifest tracking)
  - Phase 1c: Spex via `mix spex --stale` (SexySpex's manifest tracking)

  Then recalculates requirements for components with problems and evaluates tasks.

  Two entry points:
  - `validate_subagent/2` — SubagentStop: match edited files to dispatched task, evaluate
  - `validate_stop/2` — Stop: evaluate the session stack
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DirtyTracker
  alias CodeMySpec.Components.Sync, as: ComponentSync
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemAssigner
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.ProjectCoordinator.ImplementationStatus
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Pipeline
  alias CodeMySpec.Validation.TaskEvaluator

  @doc """
  Handle SubagentStop: run analysis, match edited files to dispatched task, evaluate.

  ## Options
  - `:transcript_path` - Path to the subagent's transcript file (required)
  """
  @spec validate_subagent(Scope.t(), keyword()) ::
          {:ok, :valid} | {:error, [Problem.t()] | String.t()}
  def validate_subagent(%Scope{} = scope, opts) do
    total_start = System.monotonic_time(:millisecond)
    transcript_path = Keyword.fetch!(opts, :transcript_path)

    # Sync component mtimes before checking dirty status — the file watcher's
    # debounce may not have fired yet when the hook arrives.
    sync_ms = sync_component_mtimes(scope)

    # Phase 0: Purge stale problems from before dirty tracking
    purge_stale_problems(scope)

    # Phase 1a: Static analysis on dirty components (our dirty tracking)
    {analysis_problems, analysis_ms} = run_analysis_pipeline(scope, opts)

    # Phase 1b: Tests via --stale (Elixir's manifest tracking)
    {test_problems, test_ms} = run_tests_stale(scope, opts)

    # Phase 1c: Spex via --stale (SexySpex's manifest tracking)
    {spex_problems, spex_ms} = run_spex_stale(scope)

    all_problems = analysis_problems ++ test_problems ++ spex_problems

    # Phase 2: Recalculate requirements for components with problems
    recalc_start = System.monotonic_time(:millisecond)
    recalculate_for_problem_components(scope)
    recalc_ms = System.monotonic_time(:millisecond) - recalc_start

    # Phase 3: Identify subagent task via prompt_path matching and evaluate
    eval_start = System.monotonic_time(:millisecond)
    task_result = identify_and_evaluate_task(scope, transcript_path)
    eval_ms = System.monotonic_time(:millisecond) - eval_start

    total_ms = System.monotonic_time(:millisecond) - total_start

    Logger.info(
      "[Validation] validate_subagent completed in #{total_ms}ms: " <>
        "sync=#{sync_ms}ms, analysis=#{analysis_ms}ms, tests=#{test_ms}ms, spex=#{spex_ms}ms, " <>
        "recalc=#{recalc_ms}ms, eval=#{eval_ms}ms"
    )

    combine_results(all_problems, task_result)
  end

  @doc """
  Handle Stop: run analysis, evaluate the session stack.

  ## Options
  - `:session_id` - External conversation ID for session lookup (required)
  """
  @spec validate_stop(Scope.t(), keyword()) ::
          {:ok, :valid} | {:error, [Problem.t()] | String.t()}
  def validate_stop(%Scope{} = scope, opts) do
    total_start = System.monotonic_time(:millisecond)
    session_id = Keyword.fetch!(opts, :session_id)

    # Sync component mtimes before checking dirty status — the file watcher's
    # debounce may not have fired yet when the hook arrives.
    sync_ms = sync_component_mtimes(scope)

    # Phase 0: Purge stale problems from before dirty tracking
    purge_stale_problems(scope)

    # Phase 1a: Static analysis on dirty components (our dirty tracking)
    {analysis_problems, analysis_ms} = run_analysis_pipeline(scope, opts)

    # Phase 1b: Tests via --stale (Elixir's manifest tracking)
    {test_problems, test_ms} = run_tests_stale(scope, opts)

    # Phase 1c: Spex via --stale (SexySpex's manifest tracking)
    {spex_problems, spex_ms} = run_spex_stale(scope)

    all_problems = analysis_problems ++ test_problems ++ spex_problems

    # Phase 2: Recalculate requirements for components with problems
    recalc_start = System.monotonic_time(:millisecond)
    recalculate_for_problem_components(scope)
    recalc_ms = System.monotonic_time(:millisecond) - recalc_start

    # Phase 3: Session stack evaluation
    eval_start = System.monotonic_time(:millisecond)
    session_result = TaskEvaluator.evaluate_sessions(scope, session_id)
    eval_ms = System.monotonic_time(:millisecond) - eval_start

    total_ms = System.monotonic_time(:millisecond) - total_start

    Logger.info(
      "[Validation] validate_stop completed in #{total_ms}ms: " <>
        "sync=#{sync_ms}ms, analysis=#{analysis_ms}ms, tests=#{test_ms}ms, spex=#{spex_ms}ms, " <>
        "recalc=#{recalc_ms}ms, eval=#{eval_ms}ms"
    )

    combine_results(all_problems, session_result)
  end

  @doc """
  Format a validation result into the Claude Code hook response map.
  """
  @spec format_output({:ok, :valid} | {:error, [Problem.t()] | String.t()}) :: map()
  def format_output({:ok, :valid}), do: %{}

  def format_output({:error, problems}) when is_list(problems) do
    reason =
      ProblemRenderer.render_for_feedback(problems,
        context: "Validation errors found:",
        max_problems: 20
      )

    %{"decision" => "block", "reason" => reason}
  end

  def format_output({:error, reason}) when is_binary(reason) do
    %{"decision" => "block", "reason" => reason}
  end

  # ============================================================================
  # Pre-validation: Sync component mtimes
  # ============================================================================

  # Ensures files_changed_at reflects actual file mtimes before dirty checking.
  # The file watcher runs sync_changed on a 100ms debounce, but the Stop/SubagentStop
  # hook can arrive before that debounce fires.
  defp sync_component_mtimes(%Scope{cwd: nil}), do: 0

  defp sync_component_mtimes(%Scope{cwd: cwd} = scope) do
    start = System.monotonic_time(:millisecond)

    case ComponentSync.sync_changed(scope, base_dir: cwd) do
      {:ok, _components, changed_ids} ->
        ms = System.monotonic_time(:millisecond) - start

        Logger.info(
          "[Validation] Pre-sync: #{length(changed_ids)} component(s) updated in #{ms}ms"
        )

        ms

      {:error, error} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.warning("[Validation] Pre-sync failed: #{inspect(error)}")
        ms
    end
  end

  # ============================================================================
  # Phase 0: Purge Stale Problems
  # ============================================================================

  # Problems are stale when a component has been analyzed (last_analyzed_at set)
  # but is not currently dirty. This means the analysis pipeline already ran
  # replace_problems_for_components for that component — any remaining problems
  # predate the dirty tracking system and are zombies.
  defp purge_stale_problems(scope) do
    problem_component_ids = Problems.component_ids_with_problems(scope)

    if problem_component_ids == [] do
      :ok
    else
      components = Components.list_components(scope)

      stale_ids =
        components
        |> Enum.filter(fn c ->
          c.id in problem_component_ids &&
            not is_nil(c.last_analyzed_at) &&
            not DirtyTracker.analysis_dirty?(c)
        end)
        |> Enum.map(& &1.id)

      if stale_ids != [] do
        {:ok, count} = Problems.delete_problems_for_components(scope, stale_ids)

        Logger.info(
          "[Validation] Purged #{count} stale problems from #{length(stale_ids)} analyzed components"
        )
      end
    end
  end

  # ============================================================================
  # Phase 1a: Static Analysis (our dirty tracking)
  # ============================================================================

  defp run_analysis_pipeline(scope, opts) do
    start = System.monotonic_time(:millisecond)
    dirty_components = DirtyTracker.dirty_for_analysis(scope)
    Logger.info("[Validation] #{length(dirty_components)} dirty components for analysis")

    problems =
      if dirty_components == [] do
        []
      else
        pipeline_opts = Keyword.take(opts, [:compile_output_file])
        results_by_source = Pipeline.run_scoped(scope, dirty_components, pipeline_opts)

        components = Components.list_components(scope)
        {path_index, _} = DirtyTracker.build_path_index(components, scope.active_project)
        component_ids = Enum.map(dirty_components, & &1.id)

        Enum.flat_map(results_by_source, fn {source, problems} ->
          assigned = ProblemAssigner.assign(problems, path_index)
          Problems.replace_problems_for_components(scope, component_ids, source, assigned)
          assigned
        end)
        |> tap(fn _problems ->
          DirtyTracker.record_analysis(scope, dirty_components)
        end)
      end

    ms = System.monotonic_time(:millisecond) - start
    {problems, ms}
  end

  # ============================================================================
  # Phase 1b: Tests via --stale (Elixir's manifest tracking)
  # ============================================================================

  defp run_tests_stale(%Scope{environment: nil} = _scope, _opts), do: {[], 0}

  defp run_tests_stale(%Scope{} = scope, opts) do
    start = System.monotonic_time(:millisecond)

    pipeline_opts = Keyword.take(opts, [:test_output_file])
    {:ok, problems} = Pipeline.run_tests_stale(scope, pipeline_opts)

    # Assign test problems to components
    if problems != [] do
      components = Components.list_components(scope)
      {path_index, _} = DirtyTracker.build_path_index(components, scope.active_project)
      assigned = ProblemAssigner.assign(problems, path_index)
      component_ids = assigned |> Enum.map(& &1.component_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

      if component_ids != [] do
        Problems.replace_problems_for_components(scope, component_ids, "exunit", assigned)
      end
    end

    ms = System.monotonic_time(:millisecond) - start
    {problems, ms}
  end

  # ============================================================================
  # Phase 1c: Spex via --stale (SexySpex's manifest tracking)
  # ============================================================================

  defp run_spex_stale(%Scope{environment: nil} = _scope), do: {[], 0}

  defp run_spex_stale(%Scope{} = scope) do
    start = System.monotonic_time(:millisecond)

    {:ok, problems} = Pipeline.run_spex_stale(scope)

    # Recalculate story requirements after spex run
    if problems != [] do
      stories =
        case Stories.list_project_stories(scope) do
          {:ok, s} -> CodeMySpec.Repo.preload(s, [:requirements, :component])
          _ -> []
        end

      RequirementsSync.sync_story_requirements(stories, scope)
    end

    ms = System.monotonic_time(:millisecond) - start
    {problems, ms}
  end

  # ============================================================================
  # Phase 2: Targeted Requirement Recalculation
  # ============================================================================

  defp recalculate_for_problem_components(scope) do
    problem_component_ids = Problems.component_ids_with_problems(scope)

    if problem_component_ids == [] do
      Logger.info("[Validation] No components with problems, skipping requirement recalc")
    else
      Logger.info(
        "[Validation] Recalculating requirements for #{length(problem_component_ids)} components with problems"
      )

      components = Components.list_components(scope)
      problem_components = Enum.filter(components, &(&1.id in problem_component_ids))
      Enum.each(problem_components, &RequirementsSync.recalculate_component_requirements(scope, &1))
    end
  end

  # ============================================================================
  # Phase 3: Task Identification & Evaluation (SubagentStop only)
  # ============================================================================

  defp identify_and_evaluate_task(scope, transcript_path) do
    env = scope.environment

    if is_nil(env) do
      :none
    else
      case ImplementationStatus.identify_task_from_transcript(env, transcript_path) do
        nil ->
          Logger.warning(
            "[Validation] Could not identify subagent task — no prompt_path or file match"
          )

          :none

        matched_task ->
          Logger.info(
            "[Validation] Identified task: #{matched_task["requirement"]} " <>
              "for #{matched_task["component_module"] || "project"}"
          )

          evaluate_matched_task(scope, matched_task)
      end
    end
  end

  defp evaluate_matched_task(scope, %{"component_id" => component_id} = task)
       when is_binary(component_id) do
    case Components.get_component(scope, component_id) do
      nil ->
        Logger.warning("[Validation] Component #{component_id} not found for matched task")
        :none

      component ->
        # Find the task module from the requirement name
        requirement_name = task["requirement"]
        task_module = find_task_module(requirement_name, component)

        if task_module do
          session = %{component: component, project: scope.active_project}
          call_evaluate(task_module, scope, session)
        else
          Logger.info("[Validation] No task module for requirement: #{requirement_name}")
          :none
        end
    end
  end

  defp evaluate_matched_task(_scope, _task), do: :none

  defp find_task_module(requirement_name, component) do
    # Look up the requirement definition to get satisfied_by
    definitions =
      CodeMySpec.Requirements.Registry.get_requirements_for_type(component.type)

    case Enum.find(definitions, &(&1.name == requirement_name)) do
      %{satisfied_by: module} when not is_nil(module) -> module
      _ -> nil
    end
  end

  defp call_evaluate(module, scope, session) do
    module.evaluate(scope, session, [])
  rescue
    e ->
      Logger.error("[Validation] Task evaluation failed: #{Exception.message(e)}")
      {:error, "Task evaluation failed: #{Exception.message(e)}"}
  end

  # ============================================================================
  # Result Combination
  # ============================================================================

  defp combine_results(pipeline_problems, task_result) do
    # Test failures are expected in TDD mode — don't block on them.
    blocking_problems = Enum.reject(pipeline_problems, &(&1.source_type == :test))

    cond do
      blocking_problems != [] ->
        {:error, blocking_problems}

      match?({:error, _}, task_result) ->
        task_result

      match?({:ok, :invalid, _}, task_result) ->
        {:ok, :invalid, feedback} = task_result
        {:error, feedback}

      true ->
        {:ok, :valid}
    end
  end
end
