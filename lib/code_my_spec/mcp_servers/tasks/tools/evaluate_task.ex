defmodule CodeMySpec.McpServers.Tasks.Tools.EvaluateTask do
  @moduledoc """
  Evaluate a task's work and get pass/fail feedback.

  Call this when you've completed the work for a task with manual validation.
  The task's module evaluates your work against its criteria.

  On pass: the task is marked completed and the requirement is rechecked.
  On fail: you receive feedback describing what needs fixing.

  Tasks with automatic validation are evaluated by the stop hook — you don't
  need to call this for those.

  The `session_id` is injected automatically by the PreToolUse hook.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.AgentTasks.Evaluator
  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :task_id, :string,
      required: true,
      doc: "Task ID to evaluate"

    field :session_id, :string,
      doc: "Injected by hook — do not set manually"
  end

  @impl true
  def execute(%{task_id: task_id} = params, frame) do
    session_id = Map.get(params, :session_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         {:ok, task} <- find_task(session, task_id) do
      handle_evaluate(scope, session, task, frame)
    else
      {:error, :session_not_found} ->
        {:reply, TasksMapper.session_not_found(session_id || "unknown"), frame}

      {:error, :task_not_found} ->
        {:reply, TasksMapper.task_not_found(task_id), frame}

      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    session =
      Sessions.get_by_external_id(scope, session_id) ||
        safe_get_session(scope, session_id)

    case session do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _session_id) do
    {:error, "No session_id available. The PreToolUse hook should inject it automatically."}
  end

  defp safe_get_session(scope, id) do
    Sessions.get_session(scope, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp find_task(session, task_id) do
    case Session.find_task(session, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp handle_evaluate(_scope, _session, %{status: status}, frame)
       when status in [:completed, :failed, :cancelled] do
    {:reply, TasksMapper.task_already_terminal(status), frame}
  end

  defp handle_evaluate(scope, session, task, frame) do
    task_module = task.session_type

    if is_nil(task_module) do
      {:reply, TasksMapper.error("No task module configured for this task"), frame}
    else
      result = dispatch_evaluate(task_module, scope, task)

      case result do
        {:ok, :valid} ->
          {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)
          Logger.info("[EvaluateTask] #{type_name(task_module)} passed — task #{task.id} completed")
          {:reply, TasksMapper.evaluate_passed_response(task), frame}

        {:ok, :invalid, feedback} ->
          Logger.info("[EvaluateTask] #{type_name(task_module)} failed — feedback returned")
          {:reply, TasksMapper.evaluate_needs_work_response(task, feedback), frame}

        {:error, reason} ->
          Logger.warning("[EvaluateTask] #{type_name(task_module)} error: #{inspect(reason)}")
          {:reply, TasksMapper.evaluate_error_response(task, reason), frame}
      end
    end
  end

  # Modules with custom evaluate logic bypass the unified Evaluator.
  # Everything else goes through the Evaluator (FileSync + RequirementCalculator).
  defp dispatch_evaluate(module, scope, task) do
    if Evaluator.has_custom_evaluate?(module) do
      module.evaluate(scope, task)
    else
      Evaluator.evaluate(scope, task)
    end
  rescue
    e -> {:error, "Evaluation failed: #{Exception.message(e)}"}
  end

  defp type_name(module) do
    module |> Atom.to_string() |> String.split(".") |> List.last()
  end
end
