defmodule CodeMySpec.Agents.IssueWork do
  @moduledoc """
  Role-specific work across a working copy’s assigned issue bag (story 1091).
  The active issue sorts first when eligible; other bag members remain claimable.

  Bypasses the requirement graph entirely — an issue is not in it. The coder
  fixes it (`fix_issue`); once that is done QA tests it (`qa_complete`, named
  the same as a story's so `SubmitQaResult`'s contract generalizes); once QA
  passes it the coder lands it on main (`promote_issue`), which resolves it. Whose
  turn it is lives on the issue itself (`Issue.awaiting_role`, set by the
  coder's fix and by QA's attempt) rather than being derived here from `Qa`'s
  attempts — `Qa` already depends on `Agents`, so the reverse would cycle.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.AgentTasks.IssueFix
  alias CodeMySpec.AgentTasks.IssuePromote
  alias CodeMySpec.AgentTasks.IssueQa
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Users.Scope

  @waiting_for_main "Waiting for main assignment: the team is free and nothing is assigned yet."

  @doc "`Agents.Work.work_for/4`'s answer for an agent bound to an issue, or just freed of one."
  @spec execution(Scope.t(), Agent.t()) :: map()
  def execution(scope, %Agent{issue_id: id} = agent) when is_binary(id) do
    case IssueAssignment.bag(scope, agent.working_copy_id) do
      [] -> legacy_execution(scope, agent, id)
      issues -> execution(scope, agent, issues)
    end
  end

  def execution(_scope, %Agent{team_free_at: %DateTime{}}), do: blocked(@waiting_for_main)

  def execution(scope, agent, issues) when is_list(issues) do
    ordered =
      Enum.sort_by(
        issues,
        &{&1.id != agent.issue_id, Issue.severity_index(&1.severity), &1.id}
      )

    results = Enum.map(ordered, &stage(scope, agent, &1))
    actionable = Enum.flat_map(results, & &1.actionable)

    case actionable do
      [] -> blocked(Enum.map_join(results, "\n", & &1.reason))
      nodes -> %{ready(hd(nodes)) | actionable: nodes, wave: nodes, remaining: length(nodes)}
    end
  end

  defp legacy_execution(scope, agent, id) do
    case Issues.get_issue(scope, id) do
      nil -> blocked("Your team's assigned issue (#{id}) no longer exists.")
      issue -> stage(scope, agent, issue)
    end
  end

  # A resolution recorded outside this pairing's own close (`resolve_issue`
  # directly, rather than a passing `Qa.IssueQaAttempts.submit/2`) leaves the
  # team still bound and `awaiting_role` stale — settle it here instead of
  # re-offering qa_complete/fix_issue for an issue that is already done.
  defp stage(scope, _agent, %{status: status} = issue) when status in [:resolved, :dismissed] do
    IssueAssignment.free(scope, issue)
    blocked("Issue #{issue.id} is already #{status}; your team is free for new assignment.")
  end

  defp stage(_scope, %Agent{role: :coding}, %{awaiting_role: :coding} = issue),
    do: ready(fix_node(issue))

  defp stage(_scope, %Agent{role: :coding}, %{awaiting_role: :promote} = issue),
    do: ready(promote_node(issue))

  defp stage(_scope, %Agent{role: :qa}, %{awaiting_role: :promote} = issue),
    do: blocked("QA passed your team's fix for issue #{issue.id}; waiting for it to land.")

  defp stage(_scope, %Agent{role: :coding}, issue),
    do: blocked("Your team's fix for issue #{issue.id} is submitted; waiting on QA.")

  defp stage(_scope, %Agent{role: :qa}, %{awaiting_role: :qa} = issue), do: ready(qa_node(issue))

  defp stage(_scope, %Agent{role: :qa}, issue),
    do:
      blocked(
        "Your team's assigned issue (#{issue.id}) is still being fixed; nothing for QA yet."
      )

  defp stage(_scope, _agent, issue),
    do: blocked("No work is defined for this role on issue #{issue.id}.")

  defp fix_node(issue) do
    issue_node("fix_issue", issue, IssueFix, :coding, "Fix issue #{issue.id}: #{issue.title}")
  end

  defp promote_node(issue) do
    issue_node(
      "promote_issue",
      issue,
      IssuePromote,
      :coding,
      "Land the fix for issue #{issue.id}: #{issue.title}"
    )
  end

  defp qa_node(issue) do
    issue_node(
      "qa_complete",
      issue,
      IssueQa,
      :qa,
      "Test the fix for issue #{issue.id}: #{issue.title}"
    )
  end

  defp issue_node(name, issue, module, role, description) do
    %{
      name: name,
      entity_type: "issue",
      entity_id: issue.id,
      entity_name: issue.title,
      orchestrated_by: nil,
      parent_entity_id: nil,
      parent_entity_name: nil,
      execution_type: :main_agent,
      validation_type: :automatic,
      satisfied_by: module,
      role: role,
      description: description,
      satisfied: false
    }
  end

  defp ready(node),
    do: %{
      status: :ready,
      story: nil,
      actionable: [node],
      wave: [node],
      remaining: 0,
      blockers: [],
      reason: ""
    }

  defp blocked(reason),
    do: %{
      status: :blocked,
      story: nil,
      actionable: [],
      wave: [],
      remaining: 0,
      blockers: [],
      reason: reason
    }
end
