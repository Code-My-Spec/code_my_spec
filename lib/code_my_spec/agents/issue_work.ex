defmodule CodeMySpec.Agents.IssueWork do
  @moduledoc """
  The work offered to a team bound to an issue, or freed of one (story 1091).

  Bypasses the requirement graph entirely — an issue is not in it. The coder
  fixes it (`fix_issue`); once that is done QA tests it (`qa_complete`, named
  the same as a story's so `SubmitQaResult`'s contract generalizes). Whose
  turn it is lives on the issue itself (`Issue.awaiting_role`, set by the
  coder's fix and by QA's attempt) rather than being derived here from `Qa`'s
  attempts — `Qa` already depends on `Agents`, so the reverse would cycle.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.AgentTasks.IssueFix
  alias CodeMySpec.AgentTasks.IssueQa
  alias CodeMySpec.Issues
  alias CodeMySpec.Users.Scope

  @waiting_for_main "Waiting for main assignment: the team is free and nothing is assigned yet."

  @doc "`Agents.Work.work_for/4`'s answer for an agent bound to an issue, or just freed of one."
  @spec execution(Scope.t(), Agent.t()) :: map()
  def execution(scope, %Agent{issue_id: id} = agent) when is_binary(id) do
    case Issues.get_issue(scope, id) do
      nil -> blocked("Your team's assigned issue (#{id}) no longer exists.")
      issue -> stage(agent, issue)
    end
  end

  def execution(_scope, %Agent{team_free_at: %DateTime{}}), do: blocked(@waiting_for_main)

  defp stage(%Agent{role: :coding}, %{awaiting_role: :coding} = issue), do: ready(fix_node(issue))

  defp stage(%Agent{role: :coding}, issue),
    do: blocked("Your team's fix for issue #{issue.id} is submitted; waiting on QA.")

  defp stage(%Agent{role: :qa}, %{awaiting_role: :qa} = issue), do: ready(qa_node(issue))

  defp stage(%Agent{role: :qa}, issue),
    do: blocked("Your team's assigned issue (#{issue.id}) is still being fixed; nothing for QA yet.")

  defp stage(_agent, issue), do: blocked("No work is defined for this role on issue #{issue.id}.")

  defp fix_node(issue) do
    issue_node("fix_issue", issue, IssueFix, :coding, "Fix issue #{issue.id}: #{issue.title}")
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
