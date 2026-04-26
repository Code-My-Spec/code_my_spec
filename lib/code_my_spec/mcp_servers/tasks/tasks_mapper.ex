defmodule CodeMySpec.McpServers.Tasks.TasksMapper do
  @moduledoc """
  Maps task lifecycle data to MCP responses using a hybrid format:
  human-readable markdown + JSON data for programmatic access.
  """

  alias Anubis.Server.Response

  def prompt_response(prompt, task) do
    footer = "\n\n---\nTask ID: `#{task.id}` — when done, stop the session so the hook can validate."

    Response.tool()
    |> Response.text(prompt <> footer)
  end

  def evaluate_passed_response(task, info \\ nil)

  def evaluate_passed_response(task, nil) do
    task_name = task_type_name(task)

    Response.tool()
    |> Response.text("# #{task_name}: Passed\n\nTask completed successfully.\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin.")
  end

  def evaluate_passed_response(task, info) when is_binary(info) and info != "" do
    task_name = task_type_name(task)

    Response.tool()
    |> Response.text(
      "# #{task_name}: Passed\n\nTask completed successfully.\n\n#{info}\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin."
    )
  end

  def evaluate_passed_response(task, _), do: evaluate_passed_response(task, nil)

  def evaluate_needs_work_response(task, feedback) do
    task_name = task_type_name(task)

    Response.tool()
    |> Response.text("# #{task_name}: Needs work\n\n#{feedback}")
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

  defp task_type_name(task) do
    if task.session_type,
      do: task.session_type |> inspect() |> String.split(".") |> List.last(),
      else: "Task"
  end
end
