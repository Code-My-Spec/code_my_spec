defmodule CodeMySpec.McpServers.Requirements.Tools.AnAgentsOwnBlockedTaskIsNotOfferedTest do
  @moduledoc """
  `get_next_requirement` offers nothing `start_task` would refuse.

  metric_flow's coding agent tapped out of its only task on 2026-09-27. Every
  nudge after that asked `get_next_requirement`, which offered the blocked task
  back; `start_task` refused it ("Task ... is blocked") and the agent spun
  (467310a7). `Work.withheld?/3` is the definition both now share.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    scope = %{scope | active_working_copy_id: copy.id}
    story_fixture(scope)
    Requirements.recompute(scope)

    role =
      Enum.find(
        [:product, :main, :coding, :qa],
        &(Requirements.actionable_for_role(scope, &1) != [])
      )

    [node | _] = Requirements.actionable_for_role(scope, role)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: to_string(role),
        continuous: true,
        status: :running,
        working_copy: "/tmp/withheld-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    %{scope: scope, agent: agent, frame: frame, node: node}
  end

  defp claim(ctx) do
    {:reply, started, _} =
      StartTask.execute(
        %{
          entity_type: ctx.node.entity_type,
          entity_id: to_string(ctx.node.entity_id),
          requirement_name: ctx.node.name
        },
        ctx.frame
      )

    refute started.isError, text(started)
    [_, task_id] = Regex.run(~r/([0-9a-f]{8}-[0-9a-f-]{27})/, text(started))
    task_id
  end

  test "its own task blocked on a pending tap_out is not offered", ctx do
    task_id = claim(ctx)
    {:reply, tapped, _} = TapOut.execute(%{task_id: task_id}, ctx.frame)
    refute tapped.isError, text(tapped)

    {:reply, next, _} = GetNextRequirement.execute(%{}, ctx.frame)

    refute text(next) =~ "requirement_name=`#{ctx.node.name}`", """
    The agent was offered the task it tapped out of. `start_task` refuses it —
    "is blocked; its blocker has not been resolved" — so every nudge spins.

    #{text(next)}
    """
  end

  test "its own active task is still offered, since start_task resumes it", ctx do
    _task_id = claim(ctx)
    {:reply, next, _} = GetNextRequirement.execute(%{}, ctx.frame)
    assert text(next) =~ "requirement_name=`#{ctx.node.name}`"
  end

  # e96115a9: the same tap-out has to be somewhere a main agent can settle it.
  test "the pending tap_out is listed and answer_notification settles it", ctx do
    task_id = claim(ctx)
    {:reply, _, _} = TapOut.execute(%{task_id: task_id}, ctx.frame)
    request = Notifications.get_pending_tap_out_request(ctx.agent.id, task_id)
    main = %Frame{assigns: %{current_scope: ctx.scope}}

    {:reply, listed, _} = ListNotifications.execute(%{}, main)
    assert text(listed) =~ request.id

    {:reply, decided, _} = AnswerNotification.execute(%{id: request.id, decision: "allow"}, main)
    refute decided.isError, text(decided)
    {:reply, after_, _} = ListNotifications.execute(%{}, main)
    refute text(after_) =~ request.id
  end

  defp text(response), do: hd(Response.to_protocol(response)["content"])["text"]
end
