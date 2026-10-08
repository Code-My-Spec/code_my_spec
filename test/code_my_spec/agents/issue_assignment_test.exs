defmodule CodeMySpec.Agents.IssueAssignmentTest do
  @moduledoc """
  Story 1091: an issue is bound to a working copy's coding and QA team the
  same way a story is bound to it (a31f1cd6), on `Agent.issue_id`.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.AgentTasks.IssueFix
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
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

  test "main can request corrections after a completed fix without a failed QA attempt", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)
    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

    {:ok, coding} =
      TaskOwner.add_task(ctx.scope, reload(coding), %{
        status: :completed,
        requirement_name: "fix_issue",
        issue_id: ctx.issue.id,
        session_type: IssueFix
      })

    [completed] = coding.tasks
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)

    main = agent(ctx.scope, :main, copy_id)
    main_frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: main.id}}

    {:reply, requested, _} =
      AssignIssueToWorkingCopy.execute(
        %{
          issue_id: ctx.issue.id,
          working_copy_id: copy_id,
          rework: true,
          reason: "The submitted fix fails the named regression files."
        },
        main_frame
      )

    refute requested.isError
    updated = Issues.get_issue(ctx.scope, ctx.issue.id)

    assert updated.status == :accepted
    assert updated.awaiting_role == :coding
    assert updated.description =~ "The submitted fix fails the named regression files."
    assert reload(qa).issue_id == ctx.issue.id
    assert Agents.Work.work_for(ctx.scope, :qa, reload(qa)).actionable == []

    assert [%{name: "fix_issue", entity_id: issue_id}] =
             Agents.Work.claimable_work(ctx.scope, reload(coding))

    assert issue_id == ctx.issue.id

    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: coding.id}}

    {:reply, started, _} =
      StartTask.execute(
        %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id},
        frame
      )

    refute started.isError
    assert TaskOwner.find_task(reload(coding), completed.id).status == :completed
    assert TaskOwner.active_task(reload(coding)).id != completed.id
  end

  test "corrections require a reason and preserve the QA turn on refusal", ctx do
    copy_id = copy(ctx.scope)
    agent(ctx.scope, :coding, copy_id)
    agent(ctx.scope, :qa, copy_id)
    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)

    assert {:error, _} =
             Agents.assign_issue_to_working_copy(
               ctx.scope,
               ctx.issue.id,
               copy_id,
               rework: true,
               reason: "  "
             )

    unchanged = Issues.get_issue(ctx.scope, ctx.issue.id)
    assert unchanged.awaiting_role == :qa
    assert unchanged.description == ctx.issue.description
  end

  test "corrections cannot interrupt an active QA task", ctx do
    copy_id = copy(ctx.scope)
    agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)
    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)

    {:ok, _} =
      TaskOwner.add_task(ctx.scope, reload(qa), %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: ctx.issue.id
      })

    assert {:error, _} =
             Agents.assign_issue_to_working_copy(
               ctx.scope,
               ctx.issue.id,
               copy_id,
               rework: true,
               reason: "Known regression"
             )

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :qa
    assert TaskOwner.active_task(reload(qa)).status == :active
  end

  test "a coder cannot request its own return from QA", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    agent(ctx.scope, :qa, copy_id)
    {:ok, assigned} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    {:ok, _} = Issues.set_awaiting_role(ctx.scope, assigned, :qa)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: coding.id}}

    {:reply, refused, _} =
      AssignIssueToWorkingCopy.execute(
        %{issue_id: ctx.issue.id, working_copy_id: copy_id, rework: true, reason: "Try again"},
        frame
      )

    assert refused.isError
    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :qa
  end

  test "binds both the coding and qa agent on the destination copy", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    qa = agent(ctx.scope, :qa, copy_id)

    assert {:ok, updated} =
             Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

    assert updated.assigned_working_copy_id == copy_id
    assert reload(coding).issue_id == ctx.issue.id
    assert reload(qa).issue_id == ctx.issue.id
  end

  test "an unresolved blocked issue task is not claimable or stalled", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

    {:ok, coding} =
      TaskOwner.add_task(ctx.scope, reload(coding), %{
        status: :blocked,
        requirement_name: "fix_issue",
        issue_id: ctx.issue.id,
        blocked_at: DateTime.utc_now(),
        blocker_type: :question,
        blocker_id: Ecto.UUID.generate(),
        blocked_reason: "Waiting for an escalated decision"
      })

    assert Agents.Work.claimable_work(ctx.scope, coding) == []
    execution = Agents.Work.work_for(ctx.scope, :coding, coding)
    assert execution.status == :blocked
    assert execution.wave == []

    entry = Enum.find(Agents.Main.list_agent_work(ctx.scope), &(&1.agent_id == coding.id))
    assert entry.idle?
    assert Digest.stalled(%Digest{work: [entry]}) == []
  end

  test "an answered blocker makes its issue task claimable again", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

    {:ok, coding} =
      TaskOwner.add_task(ctx.scope, reload(coding), %{
        status: :blocked,
        requirement_name: "fix_issue",
        issue_id: ctx.issue.id,
        blocked_at: DateTime.utc_now(),
        blocker_type: :question,
        blocker_id: Ecto.UUID.generate(),
        blocker_resolved_at: DateTime.utc_now()
      })

    assert [%{entity_id: issue_id, name: "fix_issue"}] =
             Agents.Work.claimable_work(ctx.scope, coding)

    assert issue_id == ctx.issue.id
    assert Agents.Work.work_for(ctx.scope, :coding, coding).status == :ready
  end

  test "a blocked task for another issue does not withhold the assigned issue", ctx do
    copy_id = copy(ctx.scope)
    coding = agent(ctx.scope, :coding, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    other = issue_fixture(ctx.scope, %{status: :accepted})

    {:ok, coding} =
      TaskOwner.add_task(ctx.scope, reload(coding), %{
        status: :blocked,
        requirement_name: "fix_issue",
        issue_id: other.id,
        blocked_at: DateTime.utc_now(),
        blocker_type: :question,
        blocker_id: Ecto.UUID.generate()
      })

    assert [%{entity_id: issue_id, name: "fix_issue"}] =
             Agents.Work.claimable_work(ctx.scope, coding)

    assert issue_id == ctx.issue.id
  end

  test "a copy with no coding or qa agent has nobody to hold the issue", ctx do
    copy_id = copy(ctx.scope)

    assert {:error, :no_team} =
             Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
  end

  test "an issue that does not exist is refused", ctx do
    copy_id = copy(ctx.scope)
    agent(ctx.scope, :coding, copy_id)
    agent(ctx.scope, :qa, copy_id)

    assert {:error, :not_found} =
             Agents.assign_issue_to_working_copy(ctx.scope, Ecto.UUID.generate(), copy_id)
  end

  test "a working copy outside the project is refused", ctx do
    assert {:error, :not_found} =
             Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, Ecto.UUID.generate())
  end

  test "moving an issue to another team frees the old team and carries its open task", ctx do
    copy_a = copy(ctx.scope)
    coding_a = agent(ctx.scope, :coding, copy_a)
    qa_a = agent(ctx.scope, :qa, copy_a)

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_a)

    {:ok, coding_a} =
      TaskOwner.add_task(ctx.scope, coding_a, %{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "fix_issue",
        issue_id: ctx.issue.id
      })

    task = TaskOwner.active_task(coding_a)

    copy_b = copy(ctx.scope)
    coding_b = agent(ctx.scope, :coding, copy_b)
    qa_b = agent(ctx.scope, :qa, copy_b)

    assert {:ok, updated} =
             Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_b)

    assert updated.assigned_working_copy_id == copy_b

    assert reload(coding_a).issue_id == nil
    assert reload(qa_a).issue_id == nil
    assert TaskOwner.find_task(reload(coding_a), task.id) == nil

    assert reload(coding_b).issue_id == ctx.issue.id
    assert reload(qa_b).issue_id == ctx.issue.id
    moved = TaskOwner.find_task(reload(coding_b), task.id)
    assert moved.status == :active
    assert moved.requirement_name == "fix_issue"
    assert moved.issue_id == ctx.issue.id
  end

  # 91863fd2 — a bind was one-way. `assign/4` refused a nil `working_copy_id`
  # ("working_copy_id is required, expected type of :string" at the tool), and
  # no other reachable tool named unbinding, so a mistaken or stale bind could
  # not be reversed. Reversing a routing decision is ordinary; every other
  # routing step in this system is reversible.
  describe "clearing the binding" do
    test "clears the binding and frees the team", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      qa = agent(ctx.scope, :qa, copy_id)

      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

      assert reload(coding).issue_id == ctx.issue.id

      assert {:ok, cleared} =
               Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, nil)

      assert cleared.assigned_working_copy_id == nil

      # The team is no longer bound to it, same as a reassignment frees the
      # copy it moved away from.
      assert reload(coding).issue_id == nil
      assert reload(qa).issue_id == nil
    end

    test "clearing an unbound issue is a no-op rather than an error", ctx do
      assert ctx.issue.assigned_working_copy_id == nil

      assert {:ok, cleared} =
               Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, nil)

      assert cleared.assigned_working_copy_id == nil
    end

    test "a cleared issue is no longer the copy's assigned work", ctx do
      copy_id = copy(ctx.scope)
      agent(ctx.scope, :coding, copy_id)

      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

      assert CodeMySpec.Issues.assigned_to_copy(ctx.scope, copy_id).id == ctx.issue.id

      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, nil)

      assert CodeMySpec.Issues.assigned_to_copy(ctx.scope, copy_id) == nil
    end
  end

  # 91863fd2, found while fixing it: `free/2` frees the team but never cleared
  # `issue.assigned_working_copy_id`, so a stale binding outlived a
  # normally-finished issue, not just a mistaken one — the field stopped
  # meaning "the copy working this" and meant "the last copy that ever did".
  describe "free/2 clears the binding" do
    test "finishing an issue releases its binding", ctx do
      copy_id = copy(ctx.scope)
      agent(ctx.scope, :coding, copy_id)

      {:ok, bound} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      assert bound.assigned_working_copy_id == copy_id

      assert :ok = IssueAssignment.free(ctx.scope, bound)

      assert reload_issue(ctx.issue.id).assigned_working_copy_id == nil
    end
  end

  defp reload_issue(id), do: Repo.get!(CodeMySpec.Issues.Issue, id)
end
