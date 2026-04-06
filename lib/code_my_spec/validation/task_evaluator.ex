defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks via the Stop hook.

  Looks up the DB session by external conversation ID, finds the active task,
  and evaluates it via the task module's `evaluate/2` callback.
  """

  require Logger

  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

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
end
