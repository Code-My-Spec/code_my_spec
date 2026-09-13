defmodule CodeMySpec.McpServers.Tasks.TasksMapper do
  @moduledoc """
  Maps task lifecycle data to MCP responses using a hybrid format:
  human-readable markdown + JSON data for programmatic access.
  """

  alias Anubis.Server.Response

  def prompt_response(prompt, task) do
    footer =
      "\n\n---\nTask ID: `#{task.id}` — when done, stop the session so the hook can validate."

    text_response(prompt <> footer)
  end

  def evaluate_passed_response(task, info \\ nil)

  def evaluate_passed_response(task, nil) do
    task_name = task_type_name(task)

    text_response(
      "# #{task_name}: Passed\n\nTask completed successfully.\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin."
    )
  end

  def evaluate_passed_response(task, info) when is_binary(info) and info != "" do
    task_name = task_type_name(task)

    text_response(
      "# #{task_name}: Passed\n\nTask completed successfully.\n\n#{info}\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin."
    )
  end

  def evaluate_passed_response(task, _), do: evaluate_passed_response(task, nil)

  def evaluate_needs_work_response(task, feedback) do
    task_name = task_type_name(task)

    text_response("# #{task_name}: Needs work\n\n#{feedback}")
  end

  @doc """
  The evaluator declined to judge this task, and left it active.

  `QaStory` answers this for a task a sub-agent owns and has not submitted for
  yet — the third outcome beside pass and needs-work, added because returning
  `:valid` there completed the sub-agent's task out from under it (`7f79b855`).
  The stop hook already had a clause for it; this surface did not, so an
  explicit `evaluate_task` on such a task raised a `CaseClauseError` and the
  caller got a bare "Internal error" with nothing to act on (`229a42e7`).

  Not an error response. Nothing went wrong, and the caller's next move is to
  wait rather than to retry — which the text says, because "Internal error" got
  retried three times.
  """
  def evaluate_skipped_response(task, why) do
    task_name = task_type_name(task)

    text_response(
      "# #{task_name}: Left active\n\nNot yours to close: #{why}\n\n" <>
        "Nothing went wrong and nothing changed. The task stays open for whoever " <>
        "owns it, so retrying this call will answer the same thing — wait for " <>
        "them to submit instead."
    )
  end

  def evaluate_error_response(task, reason) do
    task_name = task_type_name(task)

    error_response("#{task_name} evaluation error: #{inspect(reason)}")
  end

  def session_not_found(session_id) do
    error_response("Session not found: #{session_id}")
  end

  def task_not_found(task_id) do
    error_response("Task not found: #{task_id}")
  end

  def task_already_terminal(status) do
    text_response(
      "# Task already #{status}\n\nThis task is no longer active.\n\nUse `get_next_requirement` to find your next task, then `start_task` to begin."
    )
  end

  def error(reason) when is_atom(reason), do: reason |> to_string() |> error()

  def error(reason) when is_binary(reason) do
    error_response(reason)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp task_type_name(task) do
    if task.session_type,
      do: task.session_type |> inspect() |> String.split(".") |> List.last(),
      else: "Task"
  end

  # Task prompts and feedback embed user project file content (specs, BDD
  # examples) which can carry invalid UTF-8. Anubis serializes responses with
  # Elixir's strict built-in JSON encoder, which raises {:invalid_byte, _} and
  # crashes the whole MCP session (client sees -32603). Scrub invalid bytes so
  # a stray encoding never takes down start_task/evaluate_task.
  defp text_response(content), do: Response.tool() |> Response.text(scrub(content))
  defp error_response(content), do: Response.tool() |> Response.error(scrub(content))

  defp scrub(content) when is_binary(content), do: String.replace_invalid(content)
  defp scrub(content), do: content
end
