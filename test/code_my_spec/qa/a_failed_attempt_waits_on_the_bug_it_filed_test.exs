defmodule CodeMySpec.Qa.AFailedAttemptWaitsOnTheBugItFiledTest do
  @moduledoc """
  QA that fails a story and names the bug is waiting on that bug, not asking to
  be handed the same story again.

  `qa_complete` stays unsatisfied and actionable after a failing attempt, so the
  graph re-offers the same story against the same code the moment QA finishes
  failing it. QA then says, correctly, "this needs a coding fix, not another QA
  pass" — and until `:issue` existed the only way to say so was a tap-out, which
  is a human gate.

  Measured on story 1053, 2026-09-22. Three rounds: QA found a real regression,
  filed it, tapped out; a human denied the tap-out once coding had landed the
  fix; QA re-tested and found the next one, each unmasked by the last. Every
  technical step either side was autonomous and correct — QA's diagnoses named
  the cause and coding fixed exactly that. The three denials were mechanical.

  The obvious alternative is not available: `qa_complete` (id 4) cannot take
  `story_issues_resolved` (id 6) as a prerequisite, because 6 already depends on
  4 and the graph would cycle.

  Sibling of [`ResolvingAnIssueFreesWhoeverWaitedOnItTest`], which is the other
  half — this blocks, that releases.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Qa
  alias CodeMySpec.TaskOwner

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: true,
        status: :running,
        working_copy: "/tmp/qa-waits-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    story = CodeMySpec.StoriesFixtures.story_fixture(scope)

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "qa_complete",
        story_id: story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    task = Enum.find(agent.tasks, &(&1.status == :active))

    %{scope: scope, agent: agent, story: story, task: task}
  end

  defp submit(ctx, status, issue_ids) do
    Qa.submit_qa_result(ctx.scope, %{
      task_id: ctx.task.id,
      status: status,
      scenarios: [
        %{"name" => "a scenario", "status" => to_string(status), "observation" => "what I saw"}
      ],
      issue_ids: issue_ids
    })
  end

  defp waiting_on(scope, agent_id) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent_id)

    Enum.find(fresh.tasks || [], fn task ->
      task.status == :blocked and task.blocker_type == :issue and
        is_nil(task.blocker_resolved_at)
    end)
  end

  test "a failing attempt that named an issue waits on it", ctx do
    {:ok, issue} =
      CodeMySpec.Issues.create_issue(ctx.scope, %{
        title: "Clear leaves the right input stale",
        description: "found while testing",
        severity: :high,
        scope: :app
      })

    {:ok, _attempt} = submit(ctx, :fail, [issue.id])

    blocked = waiting_on(ctx.scope, ctx.agent.id)

    assert blocked,
           """
           QA failed, named the bug, and was left holding an active task.

           The graph re-offers an unsatisfied `qa_complete` immediately, so the
           story comes straight back against unchanged code. QA has to refuse,
           and the only way to refuse is a tap-out a human must answer — three
           of them on one story in one evening.
           """

    assert blocked.blocker_id == issue.id,
           "it is waiting, but not on the issue it actually filed"
  end

  test "a passing attempt waits on nothing", ctx do
    {:ok, _attempt} = submit(ctx, :pass, [])

    refute waiting_on(ctx.scope, ctx.agent.id),
           """
           A passing attempt blocked its own task.

           A pass is the end of QA's involvement, not a reason to wait — and a
           task blocked here would hold the story's own completion hostage.
           """
  end

  # The case the block would have to guard against cannot arise: a fail without
  # issues is refused before an attempt exists, so there is never a failing
  # attempt with nothing to wait on. Pinned here because the block's
  # reliability rests on it.
  test "a failing attempt cannot name no issue", ctx do
    assert {:error, :fail_requires_issue_ids} = submit(ctx, :fail, [])

    refute waiting_on(ctx.scope, ctx.agent.id),
           "a refused submission still blocked the task"
  end
end
