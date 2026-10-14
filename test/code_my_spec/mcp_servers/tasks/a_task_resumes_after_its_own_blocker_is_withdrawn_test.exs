defmodule CodeMySpec.McpServers.Tasks.ATaskResumesAfterItsOwnBlockerIsWithdrawnTest do
  @moduledoc """
  Issue ece98062: an agent withdrew its own question, the task it blocked was
  reported released (`blocker_resolved_at` set), and `start_task` for that
  same requirement then refused with "Cannot start another agent's task" --
  as if it belonged to someone else.

  Traced: `Work.holds_node?/3` already excludes a task blocked on a *resolved*
  blocker from withholding its own node from its own owner (`is_nil(blocker_resolved_at)`
  is false once withdrawn), so `eligible_to_resume/3`'s `Work.actionable/3` check
  should already see it as actionable again. Product's correction on a related
  report (979cb183) found that report passed `agent_id: "coding"` -- a role, not
  an authenticated agent id -- which `resolve_owner/4` correctly refuses as
  someone else's work. This test exercises the full path end to end, through
  the real MCP tools, using only the authenticated owner's own id throughout
  (never a role string), to settle whether a second defect exists once
  identity is used correctly.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, coding} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        working_copy: "/tmp/withdraw-resume",
        role: :coding,
        status: :running,
        working_copy_id: copy.id
      })

    AgentPresence.present(coding)

    {:ok, _} = Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)

    %{scope: scope, issue: issue, coding: coding}
  end

  defp reload(agent), do: Repo.get!(Agents.Agent, agent.id)

  test "start_task resumes it for the authenticated owner, not refused as someone else's", ctx do
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.coding.id}}
    params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: ctx.issue.id}

    {:reply, started, _} = StartTask.execute(params, frame)
    refute started.isError, inspect(started)
    [task] = reload(ctx.coding).tasks

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        ctx.coding.id,
        %{
          "title" => "Which file owns this fix?",
          "holder" => "user",
          "questions" => [%{"question" => "a.ex or b.ex?", "options" => []}]
        },
        task.id
      )

    assert [%{status: :blocked, blocker_resolved_at: nil}] = reload(ctx.coding).tasks

    {:reply, withdrawn, _} =
      WithdrawQuestion.execute(%{question_id: request.id, reason: "moot"}, frame)

    refute withdrawn.isError, inspect(withdrawn)

    assert [%{status: :blocked, blocker_resolved_at: %DateTime{}}] = reload(ctx.coding).tasks

    {:reply, resumed, _} = StartTask.execute(params, frame)

    refute resumed.isError,
           "start_task refused to resume its own task once the blocker was withdrawn: " <>
             inspect(resumed)

    assert [%{id: task_id, status: :active, blocker_resolved_at: nil, blocker_id: nil}] =
             reload(ctx.coding).tasks

    assert task_id == task.id
  end
end
