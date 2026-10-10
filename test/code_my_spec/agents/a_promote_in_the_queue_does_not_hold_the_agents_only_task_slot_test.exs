defmodule CodeMySpec.Agents.APromoteInTheQueueDoesNotHoldTheAgentsOnlyTaskSlotTest do
  @moduledoc """
  Criterion 2021, story 1046: a queued promotion does not consume the agent's
  task slot.

  A `promote_issue` task whose promotion is already in the queue is
  legitimately still open â criterion 2017 says so â but an agent holding only
  that task is idle, not busy: the queue messages it when the candidate lands or
  is ejected, and nothing the agent does shortens the wait. Criterion 2021 adds
  the other half: it can still claim other work assigned to it.

  Issue bf57fc93 measured the cost of treating it as busy. Agent 6d915491 held
  `promote_issue` on a candidate already re-queued (b8dc441d) and was offered
  that same requirement three times in twenty seconds â each offer settling
  `ignored` in the same second its turn ended â then had the work held back and
  escalated to main as "offered 3 times and not taken". The mechanism is here:
  `admit/3` asks `idle?/1`, which asks `Agent.active_task/1`, which counts this
  task; `:busy` follows and no turn is dispatched at all.

  What must not change with it: the task stays open while the queue holds it
  (criterion 2017), and an agent holding a task the queue does *not* have is
  still busy on it.

  The instrument is `Work.admission/3` â `admit/3`'s answer, named. It has to be
  that rather than the dispatched turn: `request_turn_if_runnable/4` flattens
  every hold to `{:ok, :not_runnable}`, and a coder bound to an issue is offered
  that issue's work and nothing else (`Work.work_for/4`), so "was a turn sent"
  cannot separate `:busy` from "nothing to offer" for this setup.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Work
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
        working_copy: "/tmp/a-queued-promote",
        role: role,
        status: :running,
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)
    agent
  end

  # A second issue on the same copy, accepted and assigned to the team: work the
  # graph holds for the coder that is not the promotion it is waiting on. It is
  # also the instrument check â an agent holding nothing must be offered a turn
  # from exactly this setup.
  defp work_for_the_copy(ctx) do
    other = issue_fixture(ctx.scope)
    {:ok, accepted} = Issues.accept_issue(ctx.scope, other)
    {:ok, _assigned} = IssueAssignment.assign(ctx.scope, accepted.id, ctx.copy.id)

    Map.put(ctx, :other_issue, accepted)
  end

  # The team is bound to the issue and QA has passed it, so the coder's next
  # turn is `promote_issue` â the state bf57fc93 was measured in. Adds
  # `:task_id`.
  defp holds_promote(ctx) do
    issue = issue_fixture(ctx.scope, %{status: :accepted})
    {:ok, bound} = IssueAssignment.assign(ctx.scope, issue.id, ctx.copy.id)
    {:ok, promoted} = Issues.set_awaiting_role(ctx.scope, bound, :promote)

    {:ok, coder} =
      TaskOwner.add_task(ctx.scope, ctx.coder, %{
        status: :active,
        requirement_name: "promote_issue",
        issue_id: promoted.id
      })

    Map.put(ctx, :issue, promoted)
    |> Map.put(:task_id, Enum.find(coder.tasks, &(&1.issue_id == promoted.id)).id)
  end

  defp queued(ctx, status) do
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

  defp busy?(ctx) do
    answer = Work.admission(ctx.scope, Repo.get!(Agent, ctx.coder.id), :work_offer)
    match?({:hold, :busy}, answer)
  end

  test "an agent whose only task is a promotion already in the queue is not busy on it", ctx do
    ctx = holds_promote(ctx)
    queued(ctx, :queued)

    refute busy?(ctx),
           "a queued promote task made the agent busy, so nothing else assigned to it can land"
  end

  test "an agent whose only task is a promotion being gated is not busy on it either", ctx do
    ctx = holds_promote(ctx)
    queued(ctx, :gating)

    refute busy?(ctx)
  end

  test "the task stays open while the queue holds it", ctx do
    ctx = holds_promote(ctx)
    queued(ctx, :queued)

    busy?(ctx)

    assert %{status: :active} =
             Repo.get!(Agent, ctx.coder.id)
             |> TaskOwner.find_task(ctx.task_id)
  end

  test "an agent holding a task the queue does not have is still busy on it", ctx do
    holds_promote(ctx)

    assert busy?(ctx),
           "a held task outside the queue must still make the agent busy on it"
  end

  test "an entry the queue has already resolved leaves the agent busy on the task", ctx do
    ctx = holds_promote(ctx)
    queued(ctx, :ejected)

    assert busy?(ctx),
           "an ejected entry is the agent's to act on, not a wait"
  end

  # Instrument check: the same predicate has to answer the other way for an
  # agent holding nothing, or the assertions above prove nothing about the
  # queued promotion.
  test "an agent holding nothing is not busy", ctx do
    refute busy?(ctx)
  end
end
