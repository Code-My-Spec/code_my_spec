defmodule CodeMySpec.Agents.IssueWorkTest do
  @moduledoc """
  Story 1091's pairing resolves an issue only through a passing
  `Qa.IssueQaAttempts.submit/2`. A resolution recorded another way —
  `resolve_issue`/`dismiss_issue` called directly — must still stop
  `IssueWork` from re-offering qa_complete/fix_issue for it (011b1418).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueWork
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})
    %{scope: scope, issue: issue}
  end

  defp agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: role,
        status: :running,
        working_copy_id: copy_id
      })

    agent
  end

  defp copy(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    copy.id
  end

  defp reload(agent), do: Repo.get!(Agents.Agent, agent.id)

  test "a direct resolve_issue frees the team instead of re-offering qa_complete", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.resolve_issue(ctx.scope, ctx.issue, "Fixed directly.")

    assert %{status: :blocked, actionable: []} = IssueWork.execution(ctx.scope, reload(qa))
    assert reload(qa).issue_id == nil
    assert reload(coding).issue_id == nil
  end

  test "a direct dismiss_issue frees the team the same way", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.dismiss_issue(ctx.scope, ctx.issue, "Not real.")

    assert %{status: :blocked, actionable: []} = IssueWork.execution(ctx.scope, reload(coding))
    assert reload(coding).issue_id == nil
    assert reload(qa).issue_id == nil
  end

  test "freeing settles into waiting-for-main rather than looping", ctx do
    copy_id = copy(ctx.scope)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.resolve_issue(ctx.scope, ctx.issue, "Fixed directly.")

    assert %{status: :blocked} = IssueWork.execution(ctx.scope, reload(qa))

    assert %{status: :blocked, reason: reason} = IssueWork.execution(ctx.scope, reload(qa))
    assert reason =~ "Waiting for main assignment"
  end
end
