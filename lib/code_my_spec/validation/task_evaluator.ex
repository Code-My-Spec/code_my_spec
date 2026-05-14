defmodule CodeMySpec.Validation.TaskEvaluator do
  @moduledoc """
  Evaluates agent tasks against their requirements.

  Pure evaluation: reads DB, decides pass/fail. No file sync, no compilation,
  no static analysis — that's `Validation.validate_stop/3`'s job.
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

  @doc """
  Evaluate the active task on a session.
  """
  @spec evaluate_session(Scope.t(), Session.t()) :: {:ok, :valid} | {:error, String.t()}
  def evaluate_session(scope, session) do
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

  @doc """
  Evaluate a single task: dispatch to custom or unified evaluator, complete on pass.
  """
  @spec evaluate_task(Scope.t(), Session.t(), map()) :: {:ok, :valid} | {:error, String.t()}
  def evaluate_task(scope, session, task) do
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
          # R8: bump the per-task failure count so stop_controller can
          # detect a stuck loop (5 consecutive failures → terminate).
          Sessions.increment_failure_count(scope, session, task.id)
          {:error, feedback}

        {:error, :entity_missing} ->
          # Component or story this task points at no longer exists (likely
          # removed by ComponentSync or a manual purge). The task can't be
          # evaluated, so cancel it and let the session pull a fresh one.
          Logger.info(
            "[TaskEvaluator] Cancelling orphaned task #{task.id} — entity missing"
          )

          Sessions.complete_task(scope, session, task.id, :cancelled)
          {:ok, :valid}

        {:error, {:evaluator_crashed, detail}} ->
          # Distinguish crashes from requirement failures. The marker text at
          # the front lets agents (and humans) tell the difference from a
          # legitimate "not met" result.
          {:error,
           """
           ⚠️ Evaluator crashed (not a requirement failure) — this is a bug in the task's evaluate/2 or a checker it delegates to.

           #{detail}

           Agents: do not retry the task until the underlying bug is fixed. Report to the user.
           """}

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
      stack = __STACKTRACE__
      Logger.error("[TaskEvaluator] Evaluator crashed for #{inspect(module)}: #{Exception.format(:error, e, stack)}")

      detail =
        "#{inspect(e.__struct__)}: #{Exception.message(e)}\n\n" <>
          format_stack_summary(stack)

      {:error, {:evaluator_crashed, detail}}
  end

  defp format_stack_summary(stack) do
    stack
    |> Enum.take(5)
    |> Enum.map_join("\n", fn entry -> "  " <> Exception.format_stacktrace_entry(entry) end)
  end
end
