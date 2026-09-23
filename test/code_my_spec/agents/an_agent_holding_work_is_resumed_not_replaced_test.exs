defmodule CodeMySpec.Agents.AnAgentHoldingWorkIsResumedNotReplacedTest do
  @moduledoc """
  Starting a role whose previous agent was killed mid-task.

  A task's ownership *is* which agent's list it sits in, so an agent stopped
  while holding one leaves the claim behind on a row nothing will run again.
  `start_agent/2` always created a new row, which produced a second agent for
  the same role and copy that could not claim what the first still held.

  Measured 2026-09-23 on Broken Oaths: a promote — which restarts the shared
  dev server every working copy on the box is using — stopped coding
  `b01a95bb` at 01:50:04 while it held `code_on_running_copy` active on story
  950. Its replacement reported "get_next_requirement's only offering — story
  950's code_on_running_copy — is already claimed by another agent" and had
  nothing else to do. Four other stopped agents on that copy held active tasks
  the same way.

  John: "We need to fix the reset problem. Agents with tasks should continue on
  start."
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    # `put_destination/2` derives `working_copy` from the copy's own root and
    # overwrites whatever the caller passed, so the copy needs one or every
    # start fails validation on a field the caller did supply.
    copy =
      copy
      |> Ecto.Changeset.change(root: "/workspace/resume-#{System.unique_integer([:positive])}")
      |> CodeMySpec.Repo.update!()

    %{scope: scope, copy: copy}
  end

  defp stopped_agent_with(scope, copy, task_status) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        status: :running,
        working_copy: "/tmp/resume-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, agent} =
      TaskOwner.add_task(scope, agent, %{
        requirement_name: "code_on_running_copy",
        story_id: 950
      })

    [task] = agent.tasks

    {:ok, agent} = settle(scope, agent, task, task_status)
    {:ok, agent} = AgentsRepository.update_agent(scope, agent, %{status: :stopped})

    {agent, task}
  end

  defp settle(scope, agent, task, :active),
    do: TaskOwner.activate_task(scope, agent, task.id)

  defp settle(scope, agent, task, :completed),
    do: TaskOwner.complete_task(scope, agent, task.id)

  test "starting the role resumes the stopped agent that still holds the task", ctx do
    {stopped, task} = stopped_agent_with(ctx.scope, ctx.copy, :active)

    {:ok, started} =
      Agents.start_agent(ctx.scope, %{
        role: "coding",
        provider: "anthropic",
        working_copy_id: ctx.copy.id
      })

    assert started.id == stopped.id,
           "a replacement cannot claim what the stopped agent still holds — the " <>
             "row that owns the task is the one that has to come back"

    assert TaskOwner.find_task(started, task.id),
           "the task has to survive the resume, and by the same id: a blocker is " <>
             "keyed on question_requests.task_id, so minting a new one orphans it"

    assert started.status != :stopped
  end

  test "a stopped agent with nothing unfinished is left alone and a fresh one starts", ctx do
    {stopped, _task} = stopped_agent_with(ctx.scope, ctx.copy, :completed)

    {:ok, started} =
      Agents.start_agent(ctx.scope, %{
        role: "coding",
        provider: "anthropic",
        working_copy_id: ctx.copy.id
      })

    refute started.id == stopped.id,
           "an agent that finished its work is finished — reviving it would leave " <>
             "start_agent unable to ever give a role a clean start"
  end

  test "a holder on a different role is not resumed", ctx do
    {stopped, _task} = stopped_agent_with(ctx.scope, ctx.copy, :active)

    {:ok, started} =
      Agents.start_agent(ctx.scope, %{
        role: "qa",
        provider: "anthropic",
        working_copy_id: ctx.copy.id
      })

    refute started.id == stopped.id
    assert to_string(started.role) == "qa"
  end
end
