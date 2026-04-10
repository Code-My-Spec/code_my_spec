defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks via the Stop hook.

  Looks up the DB session by external conversation ID, finds the active task,
  and evaluates it via the task module's `evaluate/2` callback.
  """

  require Logger

  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Users.Scope

  @doc """
  Full stop evaluation: sync files, run analysis pipeline, then check requirements.

  Used by both StopController and SubagentStopController as the single entry point.

  ## Options

  - `:agent_id` — for subagent stops, resolves the subagent's task instead of active task
  """
  @spec evaluate_stop(Scope.t(), String.t() | nil, keyword()) ::
          {:ok, :valid} | {:ok, :valid, String.t()} | {:error, String.t()}
  def evaluate_stop(%Scope{} = scope, session_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    # Step 1: Sync files
    sync_files(scope)

    # Step 2: Resolve session + task
    session = session_id && Sessions.get_by_external_id(scope, session_id)
    task = resolve_task(session, agent_id)

    # Step 3: Run analysis pipeline (compile + role-based analyzers)
    case run_analysis(scope, task) do
      {:error, reason} ->
        {:error, reason}

      pipeline_result ->
        # Step 4: Evaluate task requirements
        req_result =
          if session do
            evaluate_session(scope, session)
          else
            {:ok, :valid}
          end

        case {req_result, pipeline_result} do
          {{:error, reason}, _} -> {:error, reason}
          {{:ok, :valid}, {:ok, :continue, advisory}} -> {:ok, :valid, advisory}
          {{:ok, :valid}, _} -> {:ok, :valid}
        end
    end
  end

  @doc """
  Look up session by external conversation ID, evaluate the active task.
  """
  @spec evaluate_sessions(Scope.t(), String.t()) :: {:ok, :valid} | {:error, String.t()}
  def evaluate_sessions(%Scope{} = scope, session_id) when is_binary(session_id) do
    case Sessions.get_by_external_id(scope, session_id) do
      nil ->
        {:ok, :valid}

      %Session{} = session ->
        evaluate_session(scope, session)
    end
  end

  defp evaluate_session(scope, session) do
    case Session.active_task(session) do
      nil ->
        {:ok, :valid}

      %{validation_type: :manual} ->
        Logger.info("[TaskEvaluator] Skipping manual validation task")
        {:ok, :valid}

      task ->
        evaluate_task(scope, session, task)
    end
  end

  defp evaluate_task(scope, session, task) do
    module = task.session_type

    if is_nil(module) do
      Logger.warning("[TaskEvaluator] Task #{task.id} has no session_type, skipping")
      {:ok, :valid}
    else
      type_name = module |> Atom.to_string() |> String.split(".") |> List.last()
      Logger.info("[TaskEvaluator] Evaluating task #{task.id} (#{type_name})")

      result = dispatch_evaluate(module, scope, task)

      case result do
        {:ok, :valid} ->
          Sessions.complete_task(scope, session, task.id, :completed)
          {:ok, :valid}

        {:ok, :invalid, feedback} ->
          {:error, feedback}

        {:error, reason} ->
          {:error, "Error: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch_evaluate(module, scope, task) do
    if Evaluator.has_custom_evaluate?(module) do
      module.evaluate(scope, task)
    else
      Evaluator.evaluate(scope, task)
    end
  rescue
    e ->
      {:error, "Task evaluation failed: #{Exception.message(e)}"}
  end

  # -- evaluate_stop helpers --

  defp resolve_task(nil, _agent_id), do: nil
  defp resolve_task(session, nil), do: Session.active_task(session)
  defp resolve_task(session, agent_id), do: Session.find_task_by_agent(session, agent_id)

  defp run_analysis(scope, task) do
    if task && task.started_at do
      StaticAnalysis.run_pipeline(scope, task)
    else
      {:ok, :continue}
    end
  end

  defp sync_files(%Scope{cwd: nil}), do: :ok

  defp sync_files(%Scope{cwd: cwd} = scope) do
    {:ok, file_result} = FileSync.sync(scope, base_dir: cwd)

    FileComponentSync.sync_from_files(scope,
      base_dir: cwd,
      changed_paths: file_result.changed_paths
    )

    :ok
  end
end
