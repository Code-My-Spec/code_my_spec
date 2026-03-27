defmodule CodeMySpec.McpServers.Tasks.Tools.EvaluateTask do
  @moduledoc """
  Evaluate a task's work and get pass/fail feedback.

  Call this when you've completed the work for a task with manual validation.
  The task's module evaluates your work against its criteria.

  On pass: the task is marked completed and the requirement is rechecked.
  On fail: you receive feedback describing what needs fixing.

  Tasks with automatic validation are evaluated by the stop hook — you don't
  need to call this for those.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.McpServers.Tasks.TasksMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :session_id, :string,
      required: true,
      doc: "Session ID for the task"

    field :task_id, :string,
      required: true,
      doc: "Task ID to evaluate"
  end

  @impl true
  def execute(%{session_id: session_id, task_id: task_id}, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- get_session(scope, session_id),
         {:ok, task} <- find_task(session, task_id) do
      handle_evaluate(scope, session, task, frame)
    else
      {:error, :session_not_found} ->
        {:reply, TasksMapper.session_not_found(session_id), frame}

      {:error, :task_not_found} ->
        {:reply, TasksMapper.task_not_found(task_id), frame}

      {:error, reason} ->
        {:reply, TasksMapper.error(reason), frame}
    end
  end

  defp get_session(scope, session_id) do
    session =
      try do
        Sessions.get_session(scope, session_id)
      rescue
        Ecto.Query.CastError -> nil
      end

    case session do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
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
      case call_evaluate(task_module, scope, task) do
        {:ok, :valid} ->
          {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)

          if task.requirement_id do
            Task.start(fn -> RequirementsSync.recheck_requirement(scope, task.requirement_id) end)
          end

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

  defp call_evaluate(module, scope, task) do
    module.evaluate(scope, task)
  rescue
    e -> {:error, "Evaluation failed: #{Exception.message(e)}"}
  end

  defp type_name(module) do
    module |> Atom.to_string() |> String.split(".") |> List.last()
  end
end
