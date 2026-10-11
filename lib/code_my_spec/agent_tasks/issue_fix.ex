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
      nil -> {:error, "Issue #{task.issue_id} no longer exists."}
      issue -> Issues.set_awaiting_role(scope, issue, :qa)
    end
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
    with {:ok, _issue} <- hand_to_qa(scope, task) do
      {:ok, :valid}
    end
  end

  # In CodeMySpec's own project the framework is this repository: a coder told
  # framework defects "belong to the framework" tapped out every issue in its bag.
  defp framework_line(%{project_id: project_id}) do
    if project_id == Application.get_env(:code_my_spec, :code_my_spec_project_id),
      do: "framework defects are this repository's code, so fix them here.",
      else: "framework defects belong to the framework rather than an application workaround."
  end

  defp build_prompt(issue, task) do
    """
    # Fix Issue #{issue.id}

    **#{issue.title}** [#{issue.severity}] — scope: #{issue.scope}

    #{issue.description}

    Work in the issue's scope: app defects change application code; QA defects
    repair the test tooling; docs defects correct documentation; #{framework_line(issue)}
    Add or repair regression coverage. Do not skip tests, mark them pending,
    or silence failures to make validation pass. Preserve the original behavior
    assertion unless product explicitly changes the requirement.

    Record the changed files, exact commit revision, fix evidence and validation
    results on this issue with `update_issue` before submitting it for QA.
    QA must be able to inspect what changed and what was verified.

    Make the fix and commit it, then call `evaluate_task` with task_id "#{task.id}".
    Completing this task hands the fix to QA — it does not resolve the issue. \
    Once QA passes it you land it on main through the promotion queue, and the \
    landing resolves the issue.
    """
  end
end
