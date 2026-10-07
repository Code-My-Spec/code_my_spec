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
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

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

    AgentPresence.present(agent)

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

  # The submitted fix hands the turn to QA and the issue records that on
  # itself (775b7cea). `claimable_work/3` is what `get_next_requirement` and
  # `list_agent_work` read; `work_for/4` is what the turn offer reads. An issue
  # is not in the graph, so the menu must name the issue's own node — not
  # project work the offer will never name, which is the notice saying work is
  # available while the menu says it belongs to other roles.
  test "the menu and the offer name the same work for an issue-bound agent", ctx do
    copy_id = copy(ctx.scope)
    qa = agent(ctx.scope, :qa, copy_id)

    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)

    qa = reload(qa)
    offer = Work.work_for(ctx.scope, :qa, qa)
    menu = Work.claimable_work(ctx.scope, qa)

    assert Enum.map(menu, & &1.name) == Enum.map(offer.actionable, & &1.name),
           """
           the menu names #{inspect(Enum.map(menu, & &1.name))} and the offer names \
           #{inspect(Enum.map(offer.actionable, & &1.name))}
           """

    # The same *node*, not merely a same-named one: a graph node called
    # qa_complete would belong to a story, and this must be the issue's own.
    assert [%{entity_type: "issue", entity_id: entity_id}] = menu
    assert entity_id == ctx.issue.id
  end
end
