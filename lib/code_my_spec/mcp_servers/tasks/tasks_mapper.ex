defmodule CodeMySpec.McpServers.Tasks.TasksMapper do
  @moduledoc """
  Maps task lifecycle data to MCP responses using a hybrid format:
  human-readable markdown + JSON data for programmatic access.
  """

  alias Anubis.Server.Response

  def prompt_response(prompt, task) do
    task_name =
      if task.session_type,
        do: task.session_type |> inspect() |> String.split(".") |> List.last(),
        else: "Unknown"

    data = %{
      task_id: task.id,
      task_type: task_name,
      requirement_name: task.requirement_name
    }

    # The prompt IS the content — put it front and center
    Response.tool()
    |> Response.text(prompt <> "\n\nData: " <> Jason.encode!(data))
  end

  def evaluate_passed_response(task) do
    task_name = task_type_name(task)

    summary = "# #{task_name}: Passed\n\nTask completed successfully.\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin."

    data = %{task_id: task.id, result: :passed}

    hybrid_response(summary, data)
  end

  def evaluate_needs_work_response(task, feedback) do
    task_name = task_type_name(task)
    summary = "# #{task_name}: Needs work\n\n#{feedback}"
    data = %{task_id: task.id, result: :needs_work}
    hybrid_response(summary, data)
  end

  def evaluate_error_response(task, reason) do
    task_name = task_type_name(task)

    Response.tool()
    |> Response.error("#{task_name} evaluation error: #{inspect(reason)}")
  end

  def session_not_found(session_id) do
    Response.tool()
    |> Response.error("Session not found: #{session_id}")
  end

  def task_not_found(task_id) do
    Response.tool()
    |> Response.error("Task not found: #{task_id}")
  end

  def task_already_terminal(status) do
    Response.tool()
    |> Response.text("# Task already #{status}\n\nThis task is no longer active.\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin.")
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()

  def error(reason) when is_binary(reason) do
    Response.tool()
    |> Response.error(reason)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp hybrid_response(summary, data) do
    Response.tool()
    |> Response.text(summary <> "\n\nData: " <> Jason.encode!(data))
  end

  defp task_type_name(task) do
    if task.session_type,
      do: task.session_type |> inspect() |> String.split(".") |> List.last(),
      else: "Task"
  end
end
