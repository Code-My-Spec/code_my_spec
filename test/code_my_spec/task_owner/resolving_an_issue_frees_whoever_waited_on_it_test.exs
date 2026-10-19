defmodule CodeMySpec.TaskOwner.ResolvingAnIssueFreesWhoeverWaitedOnItTest do
  @moduledoc """
  A task blocked on an issue is freed by that issue being fixed, not by a human
  answering a gate.

  QA that finds a bug files it and then has nothing it can do until another role
  fixes it. Until `:issue` existed, a task could only be blocked on a
  `:question`, a `:tap_out` or `:manual` — every one of which waits on a person.
  So QA raised a tap-out, a human gate, to express a condition the system can
  see for itself.

  Measured on story 1053, 2026-09-22. Three rounds: QA found a real regression,
  filed it, tapped out; a human denied the tap-out once coding had landed the
  fix; QA re-tested and found the next one. Every technical step was autonomous
  and correct — QA's diagnoses named the cause each time and coding fixed
  exactly that. The only human input was three mechanical "yes, that is fixed
  now".

  The obvious alternative is not available: `qa_complete` (id 4) cannot take
  `story_issues_resolved` (id 6) as a prerequisite, because 6 already depends on
  4 and the graph would cycle.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpecTest.GraphHelpers, only: [assert_woken: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Agents.Agent.Task
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

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
        working_copy: "/tmp/issue-block-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  defp blocked_on_issue(scope, agent, issue_id) do
    {:ok, agent} =
      agent
      |> CodeMySpec.Agents.Agent.add_task(%{
        status: :active,
        requirement_name: "qa_complete",
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    task = Enum.find(agent.tasks, &(&1.status == :active))

    {:ok, blocked} =
      TaskOwner.block_task(scope, agent, task.id, :issue, issue_id, reason: "waiting on the fix")

    blocked
  end

  defp waiting?(owner, issue_id) do
    Enum.any?(owner.tasks || [], fn task ->
      task.blocker_type == :issue and task.blocker_id == issue_id and
        is_nil(task.blocker_resolved_at)
    end)
  end

  test "the issue being resolved clears the block", ctx do
    issue_id = Ecto.UUID.generate()
    blocked = blocked_on_issue(ctx.scope, ctx.agent, issue_id)

    assert waiting?(blocked, issue_id), "the premise is a task waiting on that issue"

    {:ok, released} = TaskOwner.blocker_resolved(:issue, issue_id, :resolved)

    assert released == 1,
           """
           Resolving the issue freed nobody.

           This is the handoff QA cannot make for itself: it files a bug and has
           nothing to do until another role fixes it. Without this the only way
           to say so is a tap-out, which is a human gate — three of them on one
           story in one evening, each a mechanical "yes, that is fixed now".
           """

    {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    refute waiting?(fresh, issue_id), "the block was counted as released but not cleared"
  end

  test "a different issue resolving leaves it waiting", ctx do
    issue_id = Ecto.UUID.generate()
    blocked = blocked_on_issue(ctx.scope, ctx.agent, issue_id)
    assert waiting?(blocked, issue_id)

    {:ok, released} = TaskOwner.blocker_resolved(:issue, Ecto.UUID.generate(), :resolved)

    assert released == 0, "an unrelated issue released a block it had nothing to do with"

    {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)

    assert waiting?(fresh, issue_id),
           "the task stopped waiting because some other issue was fixed"
  end

  # 545653ad. The release has to fire however the issue closed, and the holder
  # has to be handed a turn that says so — a continuous agent with a released
  # block and no turn sat idle on metric_flow for over an hour.
  describe "closing the issue through its tools" do
    setup ctx do
      {:ok, issue} = Issues.accept_issue(ctx.scope, issue_fixture(ctx.scope))
      frame = %Frame{assigns: %{current_scope: ctx.scope}}
      Map.merge(ctx, %{issue: issue, frame: frame})
    end

    test "resolving it releases the agent's task and wakes the agent to resume", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.issue.id)

      response =
        ToolLibrary.run(
          "resolve_issue",
          %{issue_id: ctx.issue.id, resolution: "fixed"},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      assert_woken(ctx.agent.id,
        saying: "Your blocker issue #{ctx.issue.id} was resolved; resume"
      )

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
      refute waiting?(fresh, ctx.issue.id), "resolving the issue left its task waiting"
    end

    test "dismissing it releases the agent's task and wakes the agent to resume", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.issue.id)

      response =
        ToolLibrary.run(
          "dismiss_issue",
          %{issue_id: ctx.issue.id, reason: "not a defect"},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)

      refute waiting?(fresh, ctx.issue.id),
             """
             Dismissing the issue left its task waiting.

             A dismissed issue will never be resolved, so nothing else can ever
             clear this block — the task stays refused by `start_task` forever.
             """

      assert_woken(ctx.agent.id,
        saying: "Your blocker issue #{ctx.issue.id} was dismissed; resume"
      )
    end

    # Blocked at threshold, then re-triaged below it: nothing offers a fix
    # below `fix_issues_min_severity`, so the wait would never end.
    test "downgrading it below the fix threshold releases and wakes the waiter", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.issue.id)

      response =
        ToolLibrary.run(
          "update_issue",
          %{issue_id: ctx.issue.id, severity: "low"},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
      refute waiting?(fresh, ctx.issue.id), "a downgraded issue left its task wedged"

      assert_woken(
        ctx.agent.id,
        saying: "Your blocker issue #{ctx.issue.id} is below the project's fix threshold; resume"
      )
    end

    test "a severity change that stays at the threshold keeps it waiting", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.issue.id)

      _response =
        ToolLibrary.run(
          "update_issue",
          %{issue_id: ctx.issue.id, severity: "high"},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
      assert waiting?(fresh, ctx.issue.id), "an upgrade released a block still owed a fix"
    end
  end

  test "`:issue` is a blocker a task may actually hold", ctx do
    issue_id = Ecto.UUID.generate()
    blocked = blocked_on_issue(ctx.scope, ctx.agent, issue_id)

    task = Enum.find(blocked.tasks, &(&1.status == :blocked))

    assert task.blocker_type == :issue

    assert :issue in Task.blocker_types(),
           "an issue is not an accepted blocker, so nothing can wait on one"
  end

  # Raising the threshold drops issues below it without touching them, so the
  # waiter is wedged exactly as if the issue had been downgraded.
  describe "raising the project's fix threshold" do
    setup ctx do
      {:ok, medium} = Issues.accept_issue(ctx.scope, issue_fixture(ctx.scope))
      {:ok, high} = Issues.accept_issue(ctx.scope, issue_fixture(ctx.scope, %{severity: :high}))
      Map.merge(ctx, %{medium: medium, high: high})
    end

    test "releases what waits on an issue now below it, and wakes the waiter", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.medium.id)

      {:ok, config} = TaskOwner.update_configuration(ctx.scope, %{fix_issues_min_severity: :high})
      assert config.fix_issues_min_severity == :high

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
      refute waiting?(fresh, ctx.medium.id), "a raised threshold left its waiter wedged"

      assert_woken(
        ctx.agent.id,
        saying: "Your blocker issue #{ctx.medium.id} is below the project's fix threshold; resume"
      )
    end

    test "keeps waiting on an issue still at it", ctx do
      blocked_on_issue(ctx.scope, ctx.agent, ctx.high.id)

      {:ok, _} = TaskOwner.update_configuration(ctx.scope, %{fix_issues_min_severity: :high})

      {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
      assert waiting?(fresh, ctx.high.id), "a high issue is still owed a fix at :high"
    end
  end
end
