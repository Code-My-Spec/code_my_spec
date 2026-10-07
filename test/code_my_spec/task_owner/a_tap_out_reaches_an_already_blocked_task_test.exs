defmodule CodeMySpec.TaskOwner.ATapOutReachesAnAlreadyBlockedTaskTest do
  @moduledoc """
  ce070442 — `tap_out` refused `:task_not_active` on a blocked, unassigned task,
  leaving `cancel_task` as the only way out.

  The report: task 2e2791df (`qa_complete`, story 1085) was blocked on a
  question; once the question was answered the system said to resume with
  `start_task`, which failed with `:requirement_not_eligible` on the
  entity_id-resolution bug (ab111a52). The agent then tried `tap_out` — which
  the loop's own refusal text tells it to do ("block it with `ask_user_question`
  or `tap_out`, or `cancel_task`") — and got `:task_not_active`. That leaves
  only `cancel_task`, which abandons the attempt outright rather than asking a
  person to decide.

  The guard is in `TaskOwner.block_task/6`: it matches `%Task{status: :active}`
  and everything else falls through to `{:error, :task_not_active}`. A task
  that is already `:blocked` is therefore unreachable, even though the only
  thing `tap_out` would change about it is *which* blocker it is waiting on —
  and a person seeing it is exactly what the agent needs.

  Blocking a task that is already blocked must name the new blocker rather than
  refuse: the request is "a person should decide this", and the task is
  demonstrably not active precisely because nobody has decided the old one yet.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence

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
        role: "qa",
        continuous: true,
        status: :running,
        working_copy: "/tmp/blocked-tap-out-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  defp holding_a_task(scope, agent, status) do
    {:ok, _} =
      agent
      |> Agent.add_task(%{
        requirement_name: "qa_complete",
        status: status,
        started_at: DateTime.utc_now(),
        blocked_at: blocked_at(status),
        blocker_type: blocker_type(status),
        blocker_id: blocker_id(status)
      })
      |> Repo.update()

    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)
    fresh
  end

  defp blocked_at(:blocked), do: DateTime.utc_now()
  defp blocked_at(_status), do: nil

  defp blocker_type(:blocked), do: :question
  defp blocker_type(_status), do: nil

  defp blocker_id(:blocked), do: Ecto.UUID.generate()
  defp blocker_id(_status), do: nil

  defp the_task(agent), do: List.first(agent.tasks)

  test "a tap-out on an already-blocked task is accepted and names the tap-out as the blocker",
       %{scope: scope, agent: agent} do
    agent = holding_a_task(scope, agent, :blocked)
    task = the_task(agent)

    assert task.status == :blocked, "the task starts blocked on a question"

    assert {:ok, request} =
             Notifications.request_agent_tap_out(
               scope,
               agent.id,
               task.id,
               "the task itself is invalid"
             )

    assert request.tool_name == "tap_out",
           "the request a person decides is the tap-out, so it reaches the inbox"

    {:ok, after_block} = AgentsRepository.fetch_agent(scope, agent.id)
    blocked = TaskOwner.find_task(after_block, task.id)

    assert blocked.status == :blocked,
           "still blocked — the task has not been abandoned, it now waits on the tap-out"

    assert blocked.blocker_type == :tap_out,
           "the tap-out is the blocker a person is answering, got #{inspect(blocked.blocker_type)}"

    assert blocked.blocker_id == request.id,
           "the blocker names the request, so approving it frees exactly this task"
  end

  test "a tap-out on an active task still works", %{scope: scope, agent: agent} do
    agent = holding_a_task(scope, agent, :active)
    task = the_task(agent)

    assert {:ok, request} = Notifications.request_agent_tap_out(scope, agent.id, task.id, "stop")

    {:ok, after_block} = AgentsRepository.fetch_agent(scope, agent.id)
    blocked = TaskOwner.find_task(after_block, task.id)

    assert blocked.status == :blocked
    assert blocked.blocker_type == :tap_out
    assert blocked.blocker_id == request.id
  end

  test "a tap-out on an unknown task is still refused", %{scope: scope, agent: agent} do
    agent = holding_a_task(scope, agent, :active)

    assert {:error, :task_not_found} =
             Notifications.request_agent_tap_out(scope, agent.id, Ecto.UUID.generate(), "stop")
  end

  test "a tap-out on a completed task is still refused", %{scope: scope, agent: agent} do
    agent = holding_a_task(scope, agent, :completed)
    task = the_task(agent)

    assert {:error, :task_not_active} =
             Notifications.request_agent_tap_out(scope, agent.id, task.id, "stop")
  end
end
