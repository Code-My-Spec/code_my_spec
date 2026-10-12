defmodule CodeMySpec.Qa.IssueQaResumesTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.{AgentsRepository, IssueWork}
  alias CodeMySpec.Qa.{IssueQaAttempts, IssueQaResume, IssueQaResumes}
  alias CodeMySpec.{Issues, Repo, TaskOwner, WorkingCopies}

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device)
    {:ok, main_copy} = WorkingCopies.issue(scope, nil, device: device)
    {:ok, _} = WorkingCopies.designate_main(scope, main_copy.id)

    agents =
      Enum.map([{:main, main_copy.id}, {:coding, copy.id}, {:qa, copy.id}], fn {role, copy_id} ->
        {:ok, agent} =
          AgentsRepository.create_agent(scope, %{
            role: role,
            working_copy_id: copy_id,
            engine: :alloy,
            provider: "zai",
            status: :running,
            working_copy: "/tmp/resume-qa-test"
          })

        agent
      end)

    [main, coder, qa] = agents
    {:ok, _} = Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)
    {:ok, coder} = AgentsRepository.fetch_agent(scope, coder.id)
    completed_at = DateTime.add(DateTime.utc_now(), -10, :second)

    {:ok, coder} =
      TaskOwner.add_task(scope, coder, %{
        status: :completed,
        requirement_name: "fix_issue",
        issue_id: issue.id,
        started_at: DateTime.add(completed_at, -10, :second),
        completed_at: completed_at
      })

    fix = List.last(TaskOwner.tasks(coder))
    {:ok, qa} = AgentsRepository.fetch_agent(scope, qa.id)

    {:ok, qa} =
      TaskOwner.add_task(scope, qa, %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: issue.id
      })

    qa_task = TaskOwner.active_task(qa)

    {:ok, attempt} =
      IssueQaAttempts.submit(scope, qa, %{
        issue_id: issue.id,
        task_id: qa_task.id,
        status: :partial,
        issue_ids: [issue.id],
        scenarios: [
          %{
            name: "Operational hold",
            status: :partial,
            observation: "Source checkout was reserved"
          }
        ]
      })

    attrs = %{
      issue_id: issue.id,
      attempt_id: attempt.id,
      working_copy_id: copy.id,
      coding_agent_id: coder.id,
      coding_task_id: fix.id,
      candidate_sha: String.duplicate("a", 40),
      reason: "Source reservation cleared; main verified the preserved candidate",
      operational_only: true
    }

    %{
      scope: scope,
      issue: issue,
      main: main,
      coder: coder,
      qa: qa,
      fix: fix,
      attempt: attempt,
      attrs: attrs
    }
  end

  test "resume restores independent QA and preserves the original attempt and completed fix",
       ctx do
    before = Repo.get!(CodeMySpec.Qa.IssueQaAttempt, ctx.attempt.id)
    assert {:ok, audit} = IssueQaResumes.resume(ctx.scope, ctx.main.id, ctx.attrs)
    assert audit.candidate_sha == ctx.attrs.candidate_sha
    assert audit.authorized_by_agent_id == ctx.main.id
    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :qa
    assert Repo.get!(CodeMySpec.Qa.IssueQaAttempt, ctx.attempt.id) == before
    {:ok, coder} = AgentsRepository.fetch_agent(ctx.scope, ctx.coder.id)
    assert TaskOwner.find_task(coder, ctx.fix.id) == ctx.fix
    {:ok, qa} = AgentsRepository.fetch_agent(ctx.scope, ctx.qa.id)
    assert IssueWork.execution(ctx.scope, qa).status == :ready

    {:ok, prompt} =
      CodeMySpec.AgentTasks.IssueQa.command(ctx.scope, %{
        issue_id: ctx.issue.id,
        id: Ecto.UUID.generate()
      })

    assert prompt =~ ctx.attrs.candidate_sha
    assert prompt =~ ctx.attempt.id
    assert is_nil(Issues.get_issue(ctx.scope, ctx.issue.id).landed_commit)
    refute IssueQaAttempts.passed?(ctx.scope, ctx.issue.id)
  end

  test "an identical retry is idempotent but a changed candidate is rejected", ctx do
    assert {:ok, first} = IssueQaResumes.resume(ctx.scope, ctx.main.id, ctx.attrs)
    assert {:ok, second} = IssueQaResumes.resume(ctx.scope, ctx.main.id, ctx.attrs)
    assert first.id == second.id
    assert Repo.aggregate(IssueQaResume, :count) == 1

    assert {:error, :conflicting_or_stale_resume} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{
               ctx.attrs
               | candidate_sha: String.duplicate("b", 40)
             })
  end

  test "non-main and missing operational attestation cannot resume", ctx do
    assert {:error, :only_project_main} =
             IssueQaResumes.resume(ctx.scope, ctx.coder.id, ctx.attrs)

    assert {:error, :operational_attestation_required} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{ctx.attrs | operational_only: false})

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding
    assert Repo.aggregate(IssueQaResume, :count) == 0
  end

  test "assignment mismatch and incomplete fix evidence cannot resume", ctx do
    assert {:error, :assignment_changed} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{
               ctx.attrs
               | working_copy_id: Ecto.UUID.generate()
             })

    assert {:error, :completed_fix_required} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{
               ctx.attrs
               | coding_task_id: Ecto.UUID.generate()
             })
  end

  test "genuine failed QA remains routed to coding and an older partial cannot override it",
       ctx do
    {:ok, qa} = AgentsRepository.fetch_agent(ctx.scope, ctx.qa.id)

    {:ok, qa} =
      TaskOwner.add_task(ctx.scope, qa, %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: ctx.issue.id
      })

    task = TaskOwner.active_task(qa)

    {:ok, failed} =
      IssueQaAttempts.submit(ctx.scope, qa, %{
        issue_id: ctx.issue.id,
        task_id: task.id,
        status: :fail,
        issue_ids: [ctx.issue.id],
        scenarios: [
          %{
            name: "Implementation failure",
            status: :fail,
            observation: "Observed incorrect behavior"
          }
        ]
      })

    assert {:error, :latest_attempt_not_operational_partial} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, ctx.attrs)

    assert {:error, :latest_attempt_not_operational_partial} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{ctx.attrs | attempt_id: failed.id})

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding
    assert Repo.aggregate(IssueQaResume, :count) == 0
  end

  test "partial attempts with failed scenarios cannot be resumed", ctx do
    {:ok, qa} = AgentsRepository.fetch_agent(ctx.scope, ctx.qa.id)

    {:ok, qa} =
      TaskOwner.add_task(ctx.scope, qa, %{
        status: :active,
        requirement_name: "qa_complete",
        issue_id: ctx.issue.id
      })

    task = TaskOwner.active_task(qa)

    {:ok, partial} =
      IssueQaAttempts.submit(ctx.scope, qa, %{
        issue_id: ctx.issue.id,
        task_id: task.id,
        status: :partial,
        issue_ids: [ctx.issue.id],
        scenarios: [
          %{
            name: "Observed defect",
            status: :fail,
            observation: "Incorrect implementation behavior"
          }
        ]
      })

    assert {:error, :latest_attempt_not_operational_partial} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{ctx.attrs | attempt_id: partial.id})

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding
  end

  test "the supported tool denies coding and authorizes designated main", ctx do
    alias Anubis.Server.Frame
    alias CodeMySpec.McpServers.MainAgent.Tools.ResumeIssueQa
    coding_frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.coder.id}}
    {:reply, denied, _} = ResumeIssueQa.execute(ctx.attrs, coding_frame)
    assert denied.isError
    main_frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.main.id}}
    {:reply, allowed, _} = ResumeIssueQa.execute(ctx.attrs, main_frame)
    refute allowed.isError
    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :qa
  end

  test "newer coding work prevents resuming the historical candidate", ctx do
    {:ok, coder} = AgentsRepository.fetch_agent(ctx.scope, ctx.coder.id)

    {:ok, _} =
      TaskOwner.add_task(ctx.scope, coder, %{
        status: :active,
        requirement_name: "fix_issue",
        issue_id: ctx.issue.id,
        started_at: DateTime.utc_now()
      })

    assert {:error, :newer_coding_attempt_exists} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, ctx.attrs)

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding
    assert Repo.aggregate(IssueQaResume, :count) == 0
  end

  test "invalid candidate evidence rolls back audit and routing together", ctx do
    assert {:error, %Ecto.Changeset{}} =
             IssueQaResumes.resume(ctx.scope, ctx.main.id, %{
               ctx.attrs
               | candidate_sha: "unverified"
             })

    assert Issues.get_issue(ctx.scope, ctx.issue.id).awaiting_role == :coding
    assert Repo.aggregate(IssueQaResume, :count) == 0
  end

  test "another project cannot authorize the original issue", ctx do
    other = full_scope_fixture()
    assert {:error, :only_project_main} = IssueQaResumes.resume(other, ctx.main.id, ctx.attrs)
  end
end
