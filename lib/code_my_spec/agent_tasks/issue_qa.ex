defmodule CodeMySpec.AgentTasks.IssueQa do
  @moduledoc """
  Test the fix for the issue a working copy's team is bound to (story 1091).

  Closed through `submit_issue_qa_result`, not `evaluate_task`: a pass
  resolves the issue and frees the team, a fail sends the fix back to the
  coder and keeps the team bound to it.
  """

  alias CodeMySpec.{Issues, Paths}

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
        {:ok, build_prompt(issue, task)}
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

    Read `#{Paths.qa_plan()}` first -- it has this project's testing procedure \
    (app overview, tools registry, seed strategy), including anything specific \
    to how a fix here needs to be verified (for example, which address serves \
    this working copy's own code versus main's shared one).

    Verify the fix, then call `submit_issue_qa_result` with issue_id "#{issue.id}" \
    and task_id "#{task.id}". A passing attempt resolves the issue and frees your \
    team; a failing attempt (with findings filed via `create_issue`) sends the fix \
    back to the coder and keeps your team bound to this issue.
    """
  end
end
