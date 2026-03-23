defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks via the Stop hook.

  Looks up the DB session by external conversation ID, finds the active task,
  and evaluates it via the task module's `evaluate/3` callback.
  """

  require Logger

  alias CodeMySpec.Components
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

  # ============================================================================
  # Session evaluation
  # ============================================================================

  defp evaluate_session(scope, session) do
    case Session.active_task(session) do
      nil ->
        # No active task — nothing to evaluate
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

      enriched_session = enrich_session(scope, session)

      case call_evaluate(module, scope, enriched_session, []) do
        {:ok, :valid} ->
          # Mark task completed
          Sessions.complete_task(scope, session, task.id, :completed)
          {:ok, :valid}

        {:ok, :invalid, feedback} ->
          {:error, feedback}

        {:error, reason} ->
          {:error, "Error: #{inspect(reason)}"}
      end
    end
  end

  defp enrich_session(scope, session) do
    component =
      if session.component_module_name do
        Components.get_component_by_module_name(scope, session.component_module_name)
      end

    %{session | component: component, project: scope.active_project}
  end

  defp call_evaluate(module, scope, session, opts) do
    module.evaluate(scope, session, opts)
  rescue
    e ->
      {:error, "Task evaluation failed: #{Exception.message(e)}"}
  end
end
