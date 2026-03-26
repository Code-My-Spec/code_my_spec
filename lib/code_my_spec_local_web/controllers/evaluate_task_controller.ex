defmodule CodeMySpecLocalWeb.EvaluateTaskController do
  @moduledoc """
  Evaluates a task by calling its session_type module's evaluate/2.

  Returns markdown: either a success message or feedback for the agent to fix.
  On success, marks the task as :completed.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Requirements.Sync, as: RequirementsSync
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  def evaluate(conn, %{"session_id" => session_id, "task_id" => task_id}) do
    scope = conn.assigns.current_scope

    case Sessions.get_session(scope, session_id) do
      nil ->
        conn |> put_status(404) |> text("Session not found: #{session_id}")

      session ->
        handle_evaluate(conn, scope, session, task_id)
    end
  end

  defp handle_evaluate(conn, scope, session, task_id) do
    case Session.find_task(session, task_id) do
      nil ->
        conn |> put_status(404) |> text("Task not found: #{task_id}")

      %{status: status} when status in [:completed, :failed, :cancelled] ->
        project_name = conn.params["project_name"]
        next_task_url = "/api/projects/#{project_name}/next-task"
        text(conn, "# Task already #{status}\n\nThis task is no longer active.\n\nProceed to your next task: GET #{next_task_url}")

      task ->
        run_evaluate(conn, scope, session, task)
    end
  end

  defp run_evaluate(conn, scope, session, task) do
    task_module = task.session_type

    if is_nil(task_module) do
      text(conn, "# No task module\n\nThis task has no session_type configured.")
    else
      type_name = task_module |> Atom.to_string() |> String.split(".") |> List.last()

      case call_evaluate(task_module, scope, task) do
        {:ok, :valid} ->
          {:ok, _} = Sessions.complete_task(scope, session, task.id, :completed)
          if task.requirement_id do
            Task.start(fn -> RequirementsSync.recheck_requirement(scope, task.requirement_id) end)
          end
          Logger.info("[EvaluateTask] #{type_name} passed — task #{task.id} completed")
          project_name = conn.params["project_name"]
          next_task_url = "/api/projects/#{project_name}/next-task"
          text(conn, "# #{type_name}: Passed\n\nTask completed successfully.\n\nProceed to your next task: GET #{next_task_url}")

        {:ok, :invalid, feedback} ->
          Logger.info("[EvaluateTask] #{type_name} failed — feedback returned")
          text(conn, "# #{type_name}: Needs work\n\n#{feedback}")

        {:error, reason} ->
          Logger.warning("[EvaluateTask] #{type_name} error: #{inspect(reason)}")
          text(conn, "# #{type_name}: Error\n\n#{inspect(reason)}")
      end
    end
  end

  defp call_evaluate(module, scope, task) do
    module.evaluate(scope, task)
  rescue
    e -> {:error, "Evaluation failed: #{Exception.message(e)}"}
  end
end
