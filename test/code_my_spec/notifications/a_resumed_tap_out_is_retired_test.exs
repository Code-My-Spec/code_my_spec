defmodule CodeMySpec.Notifications.AResumedTapOutIsRetiredTest do
  @moduledoc """
  d2044280: a pending, task-less `tap_out` claims "it cannot be woken" --
  which held, until `Agents.Waiting` started treating the agent as no longer
  idle the moment it held a task again. Nothing then told the permission row
  the premise it was still asserting had already stopped being true, so two
  agents read as frozen pending a decision while they were demonstrably
  taking turns.

  `retire_resumed_tap_out/1` is the write side of that: called wherever a
  task is handed back to an agent (`start_task`), it closes the row rather
  than leaving it to outlive the thing it described.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Repo

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
        role: "coding",
        continuous: true,
        working_copy: "/tmp/resumed-tap-out-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  test "retires a pending, task-less tap-out", ctx do
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, nil, "stuck")
    assert Notifications.awaiting_answer?(ctx.agent.id)

    agent = Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id)
    :ok = Notifications.retire_resumed_tap_out(agent)

    assert Repo.get!(PermissionRequest, request.id).status == "expired"
    refute Notifications.awaiting_answer?(ctx.agent.id)
  end

  # A tap-out naming a task holds only that task (story 1080); the agent
  # working something else is not the contradiction this closes.
  test "leaves a tap-out that names a task alone", ctx do
    owner = Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id)

    {:ok, with_task} =
      CodeMySpec.TaskOwner.add_task(ctx.scope, owner, %{
        status: :active,
        requirement_name: "spec_file"
      })

    task = List.last(with_task.tasks)
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, task.id, "stuck")

    :ok = Notifications.retire_resumed_tap_out(with_task)

    assert Repo.get!(PermissionRequest, request.id).status == "pending"
  end

  test "leaves an already-decided tap-out alone", ctx do
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, nil, "stuck")
    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny")

    agent = Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id)
    :ok = Notifications.retire_resumed_tap_out(agent)

    assert Repo.get!(PermissionRequest, request.id).status == "denied"
  end

  test "is a no-op when the agent has no pending tap-out", ctx do
    agent = Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id)
    assert :ok = Notifications.retire_resumed_tap_out(agent)
  end

  test "is a no-op for anything that is not an agent" do
    assert :ok = Notifications.retire_resumed_tap_out(nil)
    assert :ok = Notifications.retire_resumed_tap_out(%{id: "not-an-agent"})
  end
end
