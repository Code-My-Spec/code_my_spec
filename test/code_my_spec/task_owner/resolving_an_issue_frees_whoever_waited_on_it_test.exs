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
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Sessions.Task
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

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
        working_copy: "/tmp/issue-block-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

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

    {:ok, released} = TaskOwner.release_issue_block(ctx.scope, issue_id)

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

    {:ok, released} = TaskOwner.release_issue_block(ctx.scope, Ecto.UUID.generate())

    assert released == 0, "an unrelated issue released a block it had nothing to do with"

    {:ok, fresh} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)

    assert waiting?(fresh, issue_id),
           "the task stopped waiting because some other issue was fixed"
  end

  test "`:issue` is a blocker a task may actually hold", ctx do
    issue_id = Ecto.UUID.generate()
    blocked = blocked_on_issue(ctx.scope, ctx.agent, issue_id)

    task = Enum.find(blocked.tasks, &(&1.status == :blocked))

    assert task.blocker_type == :issue

    assert :issue in Task.blocker_types(),
           "an issue is not an accepted blocker, so nothing can wait on one"
  end
end
