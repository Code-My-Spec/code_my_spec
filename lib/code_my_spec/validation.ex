defmodule CodeMySpec.Validation do
  @moduledoc """
  Validates files edited during Claude Code sessions.

  Parses transcripts to extract edited files, runs the generic validation pipeline,
  persists discovered problems, triggers a project sync, and evaluates agent tasks.

  Two entry points — one for SubagentStop (component task from transcript marker)
  and one for Stop (session stack evaluation). Called from the hook controller.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DirtyTracker
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemAssigner
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.Pipeline
  alias CodeMySpec.Validation.TaskEvaluator

  @doc """
  Handle SubagentStop: validate edited files and evaluate the component task.

  ## Options
  - `:transcript_path` - Path to the subagent's transcript file (required)
  """
  @spec validate_subagent(Scope.t(), keyword()) ::
          {:ok, :valid} | {:error, [Problem.t()] | String.t()}
  def validate_subagent(%Scope{} = scope, opts) do
    total_start = System.monotonic_time(:millisecond)
    transcript_path = Keyword.fetch!(opts, :transcript_path)

    # Query dirty components from the file watcher
    dirty_components = DirtyTracker.dirty_components(scope, :compiler)

    pipeline_start = System.monotonic_time(:millisecond)

    all_problems =
      if dirty_components == [] do
        Logger.info("[Validation] No dirty components, skipping pipeline")
        []
      else
        pipeline_opts = Keyword.take(opts, [:test_output_file, :compile_output_file])
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
          DirtyTracker.record_analysis(scope, dirty_components, :compiler)
          DirtyTracker.record_analysis(scope, dirty_components, :credo)
          DirtyTracker.record_analysis(scope, dirty_components, :sobelow)
          DirtyTracker.record_analysis(scope, dirty_components, :exunit)
        end)
      end

    pipeline_ms = System.monotonic_time(:millisecond) - pipeline_start

    # Task evaluation still uses transcript for task identification
    eval_start = System.monotonic_time(:millisecond)
    task_result = TaskEvaluator.evaluate_component(scope, transcript_path: transcript_path)
    eval_ms = System.monotonic_time(:millisecond) - eval_start

    total_ms = System.monotonic_time(:millisecond) - total_start

    Logger.info(
      "[Validation] validate_subagent completed in #{total_ms}ms: " <>
        "pipeline=#{pipeline_ms}ms, eval=#{eval_ms}ms, " <>
        "dirty_components=#{length(dirty_components)}"
    )

    combine_results(all_problems, task_result)
  end

  @doc """
  Handle Stop: validate edited files and evaluate the session stack.

  ## Options
  - `:transcript_path` - Path to the main session's transcript file (required)
  - `:session_id` - External conversation ID for session lookup (required)
  """
  @spec validate_stop(Scope.t(), keyword()) ::
          {:ok, :valid} | {:error, [Problem.t()] | String.t()}
  def validate_stop(%Scope{} = scope, opts) do
    total_start = System.monotonic_time(:millisecond)
    session_id = Keyword.fetch!(opts, :session_id)

    # Query dirty components from the file watcher
    dirty_components = DirtyTracker.dirty_components(scope, :compiler)

    pipeline_start = System.monotonic_time(:millisecond)

    all_problems =
      if dirty_components == [] do
        Logger.info("[Validation] No dirty components, skipping pipeline")
        []
      else
        pipeline_opts = Keyword.take(opts, [:test_output_file, :compile_output_file])
        results_by_source = Pipeline.run_scoped(scope, dirty_components, pipeline_opts)

        # Build path index for assigning problems to components
        components = Components.list_components(scope)
        {path_index, _} = DirtyTracker.build_path_index(components, scope.active_project)
        component_ids = Enum.map(dirty_components, & &1.id)

        # Assign and persist per source, then record analysis
        Enum.flat_map(results_by_source, fn {source, problems} ->
          assigned = ProblemAssigner.assign(problems, path_index)
          Problems.replace_problems_for_components(scope, component_ids, source, assigned)
          assigned
        end)
        |> tap(fn _problems ->
          DirtyTracker.record_analysis(scope, dirty_components, :compiler)
          DirtyTracker.record_analysis(scope, dirty_components, :credo)
          DirtyTracker.record_analysis(scope, dirty_components, :sobelow)
          DirtyTracker.record_analysis(scope, dirty_components, :exunit)
        end)
      end

    pipeline_ms = System.monotonic_time(:millisecond) - pipeline_start

    eval_start = System.monotonic_time(:millisecond)
    session_result = TaskEvaluator.evaluate_sessions(scope, session_id)
    eval_ms = System.monotonic_time(:millisecond) - eval_start

    total_ms = System.monotonic_time(:millisecond) - total_start

    Logger.info(
      "[Validation] validate_stop completed in #{total_ms}ms: " <>
        "pipeline=#{pipeline_ms}ms, eval=#{eval_ms}ms, " <>
        "dirty_components=#{length(dirty_components)}"
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
  # Private Helpers
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
