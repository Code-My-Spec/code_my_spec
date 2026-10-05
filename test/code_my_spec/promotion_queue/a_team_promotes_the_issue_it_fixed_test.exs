defmodule CodeMySpec.PromotionQueue.ATeamPromotesTheIssueItFixedTest do
  @moduledoc """
  e4c9bfcd, 2026-10-05: a team's copy held four accepted issues. Its promote
  named none, the queue took whichever one `assigned_to_copy/2` returned first,
  and that one had not passed QA. So every promote from the copy was refused,
  citing an unrelated issue, and three QA-passed fixes sat behind it.

  The promote task names its own issue. A bare promote, naming nothing, takes
  the issue that is waiting to be promoted.
  """

  use CodeMySpecTest.DataCase, async: false

  import Ecto.Query

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecTest.PromotionQueueHelpers

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.AgentTasks.IssuePromote
  alias CodeMySpec.Issues
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    root = CodeMySpec.TempFile.dir("team-copy")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "fix"])
    git!(root, ["config", "user.email", "t@example.com"])
    git!(root, ["config", "user.name", "T"])
    File.write!(Path.join(root, "app.ex"), "defmodule App do\nend\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "the fix"])
    on_exit(fn -> File.rm_rf(root) end)

    # The project's main copy first: the first copy to report a root is made
    # main, and main's promote is a restart rather than a queued candidate.
    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))

    {:ok, _main} =
      WorkingCopies.report_root(main, "/tmp/team-main-#{System.unique_integer([:positive])}")

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a team", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    scope = %{scope | active_working_copy_id: copy.id}
    on_exit(fn -> stop_worker(scope.active_project_id) end)

    coding = agent(scope, :coding, copy.id)
    qa = agent(scope, :qa, copy.id)

    # Older, and still waiting for QA: the one an arbitrary pick found first.
    waiting = assigned_issue(scope, copy)
    passed = assigned_issue(scope, copy)
    :ok = qa_passes(scope, qa, passed)

    %{scope: scope, coding: coding, waiting: waiting, passed: passed}
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(out)
  end

  defp agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-team",
        role: role,
        working_copy_id: copy_id
      })

    agent
  end

  defp assigned_issue(scope, copy) do
    issue = issue_fixture(scope, %{status: :accepted})
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)
    Issues.get_issue(scope, issue.id)
  end

  defp qa_passes(scope, qa, issue) do
    {:ok, _} = Issues.set_awaiting_role(scope, issue, :qa)

    {:ok, owner} =
      TaskOwner.add_task(scope, Repo.get!(Agents.Agent, qa.id), %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: issue.id
      })

    task = Enum.find(owner.tasks, &(&1.requirement_name == "qa_complete"))

    {:ok, _attempt} =
      Qa.submit_issue_qa_result(scope, owner, %{
        issue_id: issue.id,
        task_id: task.id,
        status: :pass,
        scenarios: [%{name: "Fixed", status: :pass, observation: "It is."}]
      })

    :ok
  end

  test "the promote task queues the issue it names", ctx do
    task = %{issue_id: ctx.passed.id}

    assert {:ok, :pending, text} = IssuePromote.evaluate(ctx.scope, task, ctx.coding)
    refute text =~ ctx.waiting.id

    assert [entry] = queued(ctx.scope)
    assert entry.subject_id == ctx.passed.id
  end

  test "a promote naming nothing takes the issue waiting to be promoted", ctx do
    assert {:ok, %{queued: entry}} = PromotionQueue.promote(ctx.scope, nil)
    assert entry.subject_id == ctx.passed.id
  end

  test "the promote task refuses an issue that is not this copy's", ctx do
    elsewhere = issue_fixture(ctx.scope, %{status: :accepted})

    assert {:ok, :invalid, text} =
             IssuePromote.evaluate(ctx.scope, %{issue_id: elsewhere.id}, ctx.coding)

    assert text =~ elsewhere.id
  end

  defp queued(scope) do
    project_id = scope.active_project_id

    Repo.all(from e in CodeMySpec.PromotionQueue.Entry, where: e.project_id == ^project_id)
  end
end
