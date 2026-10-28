defmodule CodeMySpec.AgentTasks.IssueQa do
  @moduledoc """
  Test the fix for the issue a working copy's team is bound to (story 1091).

  Closed through `submit_issue_qa_result`, not `evaluate_task`: a pass sends
  the coder to land the fix (the landing resolves the issue and frees the
  team), a fail sends the fix back to the coder and keeps the team bound to it.
  """

  alias CodeMySpec.Issues

  def dispatch(_node) do
    "Test the fix for the issue your team is bound to, then call " <>
      "`submit_issue_qa_result`."
  end

  @doc "Read the assigned issue and build the QA prompt. Returns `{:ok, prompt_text}`."
  def command(scope, task) do
    case Issues.get_issue(scope, task.issue_id) do
      nil ->
        {:error, "Issue #{task.issue_id} no longer exists."}

      issue ->
        resume = CodeMySpec.Qa.IssueQaResumes.latest(scope, issue.id)
        attempt = CodeMySpec.Qa.IssueQaAttempts.latest(scope, issue.id)

        evidence =
          if resume && attempt && resume.attempt_id == attempt.id &&
               resume.working_copy_id == issue.assigned_working_copy_id do
            "\nOperational QA resume audit #{resume.id} preserves partial attempt #{resume.attempt_id}. " <>
              "Verify HEAD is candidate #{resume.candidate_sha} on copy #{resume.working_copy_id} before testing. " <>
              "Stop and report a mismatch without rewinding or substituting another candidate. " <>
              "Authorization reason: #{resume.reason}. This is routing authorization, not a QA verdict or execution-slot release.\n"
          else
            ""
          end

        {:ok, build_prompt(issue, task) <> evidence}
    end
  end

  @doc "This task closes through `submit_issue_qa_result`, not here."
  def evaluate(_scope, _task),
    do: {:ok, :skip, "This task closes through submit_issue_qa_result, not evaluate_task."}

  defp build_prompt(issue, task) do
    """
    # Test The Fix For Issue #{issue.id}

    **#{issue.title}** [#{issue.severity}]

    #{issue.description}

    Read the `qa_plan` document with `read_document` first -- it has this project's testing procedure \
    (app overview, tools registry, seed strategy), including anything specific \
    to how a fix here needs to be verified (for example, which address serves \
    this working copy's own code versus main's shared one).

    Verify the fix, then call `submit_issue_qa_result` with issue_id "#{issue.id}" \
    and task_id "#{task.id}". A passing attempt sends the fix to be landed on main \
    (the landing resolves the issue and frees your team); a failing attempt (with \
    findings filed via `create_issue`) sends the fix back to the coder and keeps \
    your team bound to this issue.
    """
  end
end
