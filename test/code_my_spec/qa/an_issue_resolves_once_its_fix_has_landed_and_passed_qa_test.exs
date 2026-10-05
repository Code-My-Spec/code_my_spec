defmodule CodeMySpec.Qa.AnIssueResolvesOnceItsFixHasLandedAndPassedQaTest do
  @moduledoc """
  An issue resolves only when its fix has landed on main and its QA has
  passed (promote-queue, 2026-10-04). A pass on a fix not yet landed sends the
  coder to promote it; the landing then resolves the issue and frees the team.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueWork
  alias CodeMySpec.Issues
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    coding = agent(scope, :coding, copy.id)
    qa = agent(scope, :qa, copy.id)
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)

    %{scope: scope, issue: issue, coding: coding, qa: qa}
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

  defp reload(agent), do: Repo.get!(Agents.Agent, agent.id)

  # QA's turn, held as a task, then a passing attempt submitted against it.
  defp qa_passes(ctx) do
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, ctx.issue, :qa)

    {:ok, owner} =
      TaskOwner.add_task(ctx.scope, reload(ctx.qa), %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: ctx.issue.id
      })

    task = Enum.find(owner.tasks, &(&1.requirement_name == "qa_complete"))

    {:ok, _attempt} =
      Qa.submit_issue_qa_result(ctx.scope, owner, %{
        issue_id: ctx.issue.id,
        task_id: task.id,
        status: :pass,
        scenarios: [%{name: "Delivered", status: :pass, observation: "It arrived."}]
      })

    :ok
  end

  defp issue(ctx), do: Issues.get_issue(ctx.scope, ctx.issue.id)

  test "a pass on a fix not yet landed sends the coder to promote it", ctx do
    :ok = qa_passes(ctx)

    assert %{status: :accepted, awaiting_role: :promote} = issue(ctx)

    assert %{status: :ready, actionable: [%{name: "promote_issue"}]} =
             IssueWork.execution(ctx.scope, reload(ctx.coding))

    assert %{status: :blocked} = IssueWork.execution(ctx.scope, reload(ctx.qa))
  end

  test "the landing of a QA-passed fix resolves the issue and frees the team", ctx do
    :ok = qa_passes(ctx)

    assert :ok = Qa.issue_fix_landed(ctx.scope, ctx.issue.id, "abc123")

    assert %{status: :resolved, landed_commit: "abc123"} = issue(ctx)
    assert reload(ctx.coding).issue_id == nil
    assert reload(ctx.qa).issue_id == nil
  end

  test "the landing closes the promotion task the coder held while it waited", ctx do
    :ok = qa_passes(ctx)

    {:ok, coder} =
      TaskOwner.add_task(ctx.scope, reload(ctx.coding), %{
        status: :active,
        requirement_name: "promote_issue",
        issue_id: ctx.issue.id
      })

    %{id: task_id} = Enum.find(coder.tasks, &(&1.requirement_name == "promote_issue"))

    assert :ok = Qa.issue_fix_landed(ctx.scope, ctx.issue.id, "abc123")
    assert %{status: :completed} = TaskOwner.find_task(reload(ctx.coding), task_id)
  end

  test "a fix that landed before QA passed waits for QA, and the pass resolves it", ctx do
    assert :ok = Qa.issue_fix_landed(ctx.scope, ctx.issue.id, "abc123")
    assert %{status: :accepted, awaiting_role: :qa, landed_commit: "abc123"} = issue(ctx)

    :ok = qa_passes(ctx)

    assert %{status: :resolved} = issue(ctx)
  end

  # ea0ab1c8, 2026-10-05: the same fix was queued again after it had landed, and
  # the second landing tried to resolve a resolved issue and logged an error.
  test "a fix landing again for an issue already resolved changes nothing", ctx do
    :ok = qa_passes(ctx)
    :ok = Qa.issue_fix_landed(ctx.scope, ctx.issue.id, String.duplicate("a", 40))
    assert %{status: :resolved, resolution: resolution} = issue(ctx)

    assert :ok = Qa.issue_fix_landed(ctx.scope, ctx.issue.id, String.duplicate("b", 40))
    assert %{status: :resolved, resolution: ^resolution} = issue(ctx)
  end
end
