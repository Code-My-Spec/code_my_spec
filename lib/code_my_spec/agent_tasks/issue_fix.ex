defmodule CodeMySpec.AgentTasks.IssueFix do
  @moduledoc """
  Fix the issue a working copy's team is bound to (story 1091).

  Completing this task hands the fix to QA; it does not resolve the issue.
  A passing attempt through `submit_issue_qa_result` sends the coder to land
  the fix (`IssuePromote`), and the landing resolves the issue,
  which is also what frees the team.
  """

  alias CodeMySpec.Issues

  def dispatch(_node) do
    "Fix the issue your team is bound to, then call `evaluate_task`. That hands " <>
      "the fix to QA — it does not resolve the issue."
  end

  # Hands the issue to QA (`awaiting_role`) the moment this task passes — the
  # same turn `EvaluateTask` marks it completed, so `Agents.IssueWork`'s very
  # next read already offers `qa_complete` instead of `fix_issue` again.
  defp hand_to_qa(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil -> :ok
      issue -> Issues.set_awaiting_role(scope, issue, :qa)
    end

    :ok
  end

  @doc "Read the assigned issue and build the fix prompt. Returns `{:ok, prompt_text}`."
  def command(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil ->
        {:error, "Issue #{task.issue_id} no longer exists."}

      issue ->
        {:ok, build_prompt(issue, task)}
    end
  end

  @doc "Trusts the coder's own report; QA is the review for issue work."
  def evaluate(scope, task) do
    :ok = hand_to_qa(scope, task)
    {:ok, :valid}
  end

  defp build_prompt(issue, task) do
    """
    # Fix Issue #{issue.id}

    **#{issue.title}** [#{issue.severity}]

    #{issue.description}

    Make the fix and commit it, then call `evaluate_task` with task_id "#{task.id}".
    Completing this task hands the fix to QA — it does not resolve the issue. \
    Once QA passes it you land it on main through the promotion queue, and the \
    landing resolves the issue.
    """
  end
end
