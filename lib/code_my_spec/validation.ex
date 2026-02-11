defmodule CodeMySpec.Validation do
  @moduledoc """
  Validates files edited during Claude Code sessions.

  Parses transcripts to extract edited files, runs the generic validation pipeline,
  persists discovered problems, triggers a project sync, and evaluates agent tasks.

  Two entry points — one for SubagentStop (component task from transcript marker)
  and one for Stop (session stack evaluation). Called from the hook controller.
  """

  require Logger

  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.ProjectSync.Sync
  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.ClaudeCode.FileExtractor
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
    transcript_path = Keyword.fetch!(opts, :transcript_path)

    with {:ok, edited_files} <- extract_edited_files(transcript_path),
         false <- edited_files == [] do
      pipeline_opts = Keyword.take(opts, [:test_output_file, :compile_output_file])
      pipeline_problems = Pipeline.run(scope, edited_files, pipeline_opts)
      persist_and_sync(scope, edited_files, pipeline_problems)
      task_result = TaskEvaluator.evaluate_component(scope, transcript_path: transcript_path)
      combine_results(pipeline_problems, task_result)
    else
      true ->
        {:ok, :valid}

      {:error, reason} ->
        Logger.error("[Validation] Failed to parse transcript: #{inspect(reason)}")
        {:ok, :valid}
    end
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
    transcript_path = Keyword.fetch!(opts, :transcript_path)
    session_id = Keyword.fetch!(opts, :session_id)

    case extract_edited_files(transcript_path) do
      {:ok, edited_files} ->
        pipeline_problems =
          if edited_files == [] do
            []
          else
            pipeline_opts = Keyword.take(opts, [:test_output_file, :compile_output_file])
            Pipeline.run(scope, edited_files, pipeline_opts)
          end

        # persist + sync BEFORE evaluate so requirements are fresh
        if edited_files != [] do
          persist_and_sync(scope, edited_files, pipeline_problems)
        end

        session_result = TaskEvaluator.evaluate_sessions(scope, session_id)
        combine_results(pipeline_problems, session_result)

      {:error, reason} ->
        Logger.error("[Validation] Failed to parse transcript: #{inspect(reason)}")
        {:ok, :valid}
    end
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

  defp extract_edited_files(nil), do: {:ok, []}

  defp extract_edited_files(transcript_path) do
    case Transcripts.parse(transcript_path) do
      {:ok, transcript} ->
        files = FileExtractor.extract_edited_files(transcript)
        {:ok, files}

      {:error, _} = error ->
        error
    end
  end

  defp persist_and_sync(scope, edited_files, problems) do
    Problems.replace_problems_for_files(scope, edited_files, problems)

    sync_opts = if scope.cwd, do: [base_dir: scope.cwd], else: []

    case Sync.sync_all(scope, sync_opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("[Validation] Sync failed: #{inspect(reason)}")
    end

    :ok
  end

  defp combine_results(pipeline_problems, task_result) do
    cond do
      pipeline_problems != [] ->
        {:error, pipeline_problems}

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
