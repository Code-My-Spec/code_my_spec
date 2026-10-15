defmodule CodeMySpec.Agents.AQueuedPromotionIsNotAnIdleAgentTest do
  @moduledoc """
  Criterion 2017, story 1046: a promote task stays open until its batch lands or
  is ejected, and an agent waiting on a queued landing is not treated as idle —
  it is not nudged to act on that task, and the outcome reaches it when it
  lands.

  `Agents.Waiting` is "why an agent is legitimately waiting, or nil", and an
  agent waiting on something that will reach it when it lands is neither nudged
  at turn end (`StopDecision`) nor offered a turn (`Work`) — either one only buys
  a "still waiting" turn. Its entries cover `provider_refused`, `provisioning`,
  `tap_out`, `analysis_runs` and `question_pending`. There is none for a queued
  promotion, which is the gap issue bf57fc93 reported: at least five model turns
  spent re-evaluating a correctly open task.

  The precedent is settled rather than a design question. Issue 8f72b192 was
  the analyzer queue's version of exactly this — "a queued analyzer run never
  tells its requester, so the agent hangs" — and `analysis_runs` is the entry it
  produced. `provider_refused` shows the same shape: a wait whose end is a
  message.

  The task's lifecycle does not change here (criterion 2017 says it stays open),
  so the fix belongs in `Waiting` and not in the task.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Issues
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    coder = agent(scope, copy, :coding)
    qa = agent(scope, copy, :qa)

    %{scope: scope, copy: copy, coder: coder, qa: qa}
  end

  defp agent(scope, copy, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-queued-wait",
        role: role,
        status: :running,
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)
    agent
  end

  # The coder is bound to the issue, QA has passed it, and it holds
  # `promote_issue` — bf57fc93's arrangement.
  defp holding_a_promotion(ctx) do
    issue = issue_fixture(ctx.scope, %{status: :accepted})
    {:ok, bound} = IssueAssignment.assign(ctx.scope, issue.id, ctx.copy.id)
    {:ok, promoted} = Issues.set_awaiting_role(ctx.scope, bound, :promote)

    {:ok, _coder} =
      TaskOwner.add_task(ctx.scope, ctx.coder, %{
        status: :active,
        requirement_name: "promote_issue",
        issue_id: promoted.id
      })

    Map.put(ctx, :issue, promoted)
  end

  defp queue_holds(ctx, status) do
    changeset =
      Entry.enqueue_changeset(%{
        project_id: ctx.scope.active_project_id,
        working_copy_id: ctx.copy.id,
        commit: String.duplicate("a", 40),
        subject_type: :issue,
        subject_id: ctx.issue.id,
        requested_by_agent_id: ctx.coder.id,
        restart: true
      })

    {:ok, entry} = Repo.insert(changeset)

    {:ok, entry} = entry |> Entry.status_changeset(%{status: status}) |> Repo.update()
    entry
  end

  defp waiting?(ctx) do
    Waiting.reason(ctx.scope, Repo.get!(Agent, ctx.coder.id), :turn_end)
  end

  test "a promotion the queue holds is a reason the agent is waiting", ctx do
    ctx = holding_a_promotion(ctx)
    queue_holds(ctx, :queued)

    assert waiting?(ctx),
           "an agent waiting on a queued landing was treated as idle and nudged"
  end

  test "a promotion being gated is a reason too", ctx do
    ctx = holding_a_promotion(ctx)
    queue_holds(ctx, :gating)

    assert waiting?(ctx)
  end

  test "the reason names the promotion", ctx do
    ctx = holding_a_promotion(ctx)
    entry = queue_holds(ctx, :queued)

    assert {:promotion, id} = waiting?(ctx)
    assert id == entry.id
  end

  test "an entry the queue has already resolved is not a wait", ctx do
    ctx = holding_a_promotion(ctx)
    queue_holds(ctx, :ejected)

    refute waiting?(ctx),
           "an ejected entry is the agent's to act on, so it must still be nudged"
  end

  test "an agent holding its promotion with nothing in the queue is not waiting", ctx do
    ctx = holding_a_promotion(ctx)

    refute waiting?(ctx),
           "a promote task the queue does not have is the agent's own work"
  end

  # Instrument check: nothing at all held is not a wait either, so the
  # assertions above are about the queued promotion and not about the setup.
  test "an agent holding nothing has no reason to wait", ctx do
    refute waiting?(ctx)
  end
end
