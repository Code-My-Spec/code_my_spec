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
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Issues.Tools.SetActiveIssue
  alias CodeMySpec.McpServers.Issues.Tools.UnassignIssue
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

  defp linked_story(true, scope), do: CodeMySpec.StoriesFixtures.story_fixture(scope)
  defp linked_story(false, _scope), do: nil

  defp story_id(nil), do: nil
  defp story_id(story), do: story.id

  for {linked?, criterion} <- [{true, 2079}, {false, 2080}] do
    @linked linked?
    @tag criterion: criterion
    test "issue assignment replaces the whole team's story binding (linked: #{linked?})", ctx do
      copy_id = copy(ctx.scope)
      previous = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope)
      target = linked_story(@linked, ctx.scope)
      target_id = story_id(target)
      {:ok, issue} = Issues.update_issue(ctx.scope, ctx.issue, %{story_id: target_id})

      team =
        for role <- [:coding, :qa] do
          agent(ctx.scope, role, copy_id)
          |> Ecto.Changeset.change(story_id: previous.id)
          |> Repo.update!()
        end

      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      {:reply, response, _} =
        AssignIssueToWorkingCopy.execute(
          %{issue_id: issue.id, working_copy_id: copy_id},
          frame
        )

      refute response.isError

      for member <- team do
        updated = reload(member)
        assert updated.issue_id == issue.id
        assert updated.story_id == nil
      end

      assert WorkingCopies.team_story_id(copy_id) == nil
      assert Issues.get_issue(ctx.scope, issue.id).story_id == target_id

      destination = copy(ctx.scope)

      destination_team =
        for role <- [:coding, :qa] do
          agent(ctx.scope, role, destination)
          |> Ecto.Changeset.change(story_id: previous.id)
          |> Repo.update!()
        end

      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, issue.id, destination)

      for member <- destination_team do
        assert reload(member).issue_id == issue.id
        assert reload(member).story_id == nil
      end

      assert WorkingCopies.team_story_id(destination) == nil
      assert Enum.all?(team, &is_nil(reload(&1).issue_id))
    end
  end

  test "reassigning to the same copy preserves a blocked issue task exactly", ctx do
    copy_id = copy(ctx.scope)
    qa = agent(ctx.scope, :qa, copy_id)
    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

    {:ok, qa} =
      TaskOwner.add_task(ctx.scope, reload(qa), %{
        status: :blocked,
        requirement_name: "qa_complete",
        issue_id: ctx.issue.id,
        session_type: CodeMySpec.AgentTasks.IssueQa
      })

    {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
    assert reload(qa).tasks == qa.tasks
  end

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

  describe "project issue bags" do
    @tag criterion: 2081
    test "additive assignment, explicit priority, and role-specific claims", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      qa = agent(ctx.scope, :qa, copy_id)
      second = issue_fixture(ctx.scope, %{status: :accepted})
      {:ok, first} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, copy_id)
      assert reload(coding).issue_id == first.id
      assert reload(qa).issue_id == first.id
      assert length(Agents.assigned_issues(ctx.scope, copy_id)) == 2
      {:ok, _} = Issues.set_awaiting_role(ctx.scope, first, :qa)

      assert Enum.map(
               Agents.Work.work_for(ctx.scope, :coding, reload(coding)).actionable,
               & &1.entity_id
             ) == [second.id]

      assert Enum.map(Agents.Work.work_for(ctx.scope, :qa, reload(qa)).actionable, & &1.entity_id) ==
               [first.id]

      # A non-priority bag member must be claimable through the real task tool.
      frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: coding.id}}

      {:reply, response, _} =
        StartTask.execute(
          %{requirement_name: "fix_issue", entity_type: "issue", entity_id: second.id},
          frame
        )

      refute response.isError
      assert Enum.any?(reload(coding).tasks, &(&1.issue_id == second.id and &1.status == :active))
      {:ok, _} = Agents.prioritize_issue(ctx.scope, copy_id, second.id)
      assert reload(coding).issue_id == second.id
      assert reload(qa).issue_id == second.id
      assert length(Agents.assigned_issues(ctx.scope, copy_id)) == 2
    end

    test "priority tool refuses issues outside the bag", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      {:reply, response, _} =
        SetActiveIssue.execute(
          %{working_copy_id: copy_id, issue_id: ctx.issue.id},
          frame
        )

      assert response.isError
      assert reload(coding).issue_id == nil
    end

    @tag criterion: 2082
    test "finishing one issue retains the bag; only finishing the last frees the team", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      qa = agent(ctx.scope, :qa, copy_id)
      main_copy = copy(ctx.scope)
      {:ok, _} = WorkingCopies.designate_main(ctx.scope, main_copy)
      main = agent(ctx.scope, :main, main_copy)
      :ok = AgentPresence.absent(main)
      second = issue_fixture(ctx.scope, %{status: :accepted})
      {:ok, first} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      {:ok, second} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, copy_id)
      :ok = IssueAssignment.free(ctx.scope, first)
      assert reload(coding).issue_id == second.id
      assert reload(qa).issue_id == second.id
      assert reload(coding).team_free_at == nil
      assert Agents.Offers.list_for_agent(main.id) == []
      :ok = IssueAssignment.free(ctx.scope, second)
      assert reload(coding).issue_id == nil
      assert reload(coding).team_free_at != nil
      assert [%{status: :open}] = Agents.Offers.list_for_agent(main.id)
      assert Agents.assigned_issues(ctx.scope, copy_id) == []
      assert reload(qa).issue_id == nil
      :ok = IssueAssignment.free(ctx.scope, second)
      assert length(Agents.Offers.list_for_agent(main.id)) == 1
    end

    test "moving the priority preserves both bags and selects remaining work", ctx do
      old_copy = copy(ctx.scope)
      new_copy = copy(ctx.scope)
      old = agent(ctx.scope, :coding, old_copy)
      new = agent(ctx.scope, :coding, new_copy)
      second = issue_fixture(ctx.scope, %{status: :accepted})
      third = issue_fixture(ctx.scope, %{status: :accepted})
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, old_copy)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, old_copy)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, third.id, new_copy)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, new_copy)
      assert reload(old).issue_id == second.id
      assert reload(new).issue_id == third.id
      assert Enum.map(Agents.assigned_issues(ctx.scope, old_copy), & &1.id) == [second.id]
      assert length(Agents.assigned_issues(ctx.scope, new_copy)) == 2
    end

    test "unassign tool removes one issue without disturbing the other", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      second = issue_fixture(ctx.scope, %{status: :accepted})
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, copy_id)
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      {:reply, response, _} =
        UnassignIssue.execute(%{issue_id: ctx.issue.id}, frame)

      refute response.isError
      assert reload(coding).issue_id == second.id
      assert Enum.map(Agents.assigned_issues(ctx.scope, copy_id), & &1.id) == [second.id]
    end

    test "completing a non-priority issue preserves active work", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      second = issue_fixture(ctx.scope, %{status: :accepted})
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      {:ok, second} = Agents.assign_issue_to_working_copy(ctx.scope, second.id, copy_id)

      {:ok, _} =
        TaskOwner.add_task(ctx.scope, reload(coding), %{
          status: :active,
          requirement_name: "promote_issue",
          issue_id: second.id
        })

      :ok = IssueAssignment.free(ctx.scope, second)
      assert reload(coding).issue_id == ctx.issue.id
      assert reload(coding).team_free_at == nil
      assert [%{status: :completed, issue_id: id}] = reload(coding).tasks
      assert id == second.id
    end

    test "unassign refuses open work without losing it", ctx do
      copy_id = copy(ctx.scope)
      coding = agent(ctx.scope, :coding, copy_id)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)

      {:ok, holding} =
        TaskOwner.add_task(ctx.scope, reload(coding), %{
          status: :active,
          requirement_name: "fix_issue",
          issue_id: ctx.issue.id
        })

      assert {:error, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, nil)
      assert reload(coding).tasks == holding.tasks
      assert reload(coding).issue_id == ctx.issue.id
      assert Issues.get_issue(ctx.scope, ctx.issue.id).assigned_working_copy_id == copy_id
    end

    test "bag listing excludes other copies and includes assignment and stage", ctx do
      copy_id = copy(ctx.scope)
      agent(ctx.scope, :coding, copy_id)
      {:ok, _} = Agents.assign_issue_to_working_copy(ctx.scope, ctx.issue.id, copy_id)
      issue_fixture(ctx.scope, %{status: :accepted})
      frame = %Frame{assigns: %{current_scope: ctx.scope}}

      {:ok, %{"issues" => [row], "matched" => 1, "returned" => 1}} =
        ListIssues.script_result(
          %{working_copy_id: copy_id, severity: "all"},
          frame
        )

      assert row["id"] == ctx.issue.id
      assert row["assigned_working_copy_id"] == copy_id
      assert row["awaiting_role"] == "coding"
    end
  end

  defp reload_issue(id), do: Repo.get!(CodeMySpec.Issues.Issue, id)
end
