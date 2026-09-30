defmodule CodeMySpec.TaskOwner.ResolvingAnyBlockerFreesWhoeverWaitedOnItTest do
  @moduledoc """
  An answered question and a decided tap-out free their tasks the way a closed
  issue does (2200f9e4, the other half of 545653ad).

  metric_flow's coder 965c52a9 held eight tasks reading "blocked on question X
  (resolved — resume it with start_task)", two of them on denied tap-outs, and
  went idle at 16:14 with all of them waiting. Its wakes were the generic
  "Eligible work is available" prompt, which it answered "Same nudge, no new
  information. Stopping here." Nothing named the task it could now resume.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.SessionsFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions.Session
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

    %{scope: scope, copy: copy, agent: agent(scope, copy, "coding")}
  end

  defp agent(scope, copy, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/blocker-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    agent
  end

  defp active_task(scope, owner, requirement \\ "bdd_specs_passing") do
    {:ok, owner} =
      TaskOwner.add_task(scope, owner, %{status: :active, requirement_name: requirement})

    TaskOwner.active_task(owner)
  end

  defp ask(scope, agent, task) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Which way",
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        task.id
      )

    request
  end

  defp answer(request, opts \\ []),
    do: Notifications.answer_question_request(request.id, %{"Which way?" => "that way"}, opts)

  defp task(module, owner_id, task_id),
    do: module |> Repo.get!(owner_id) |> TaskOwner.find_task(task_id)

  defp waiting?(%{status: :blocked, blocker_resolved_at: nil}), do: true
  defp waiting?(_task), do: false

  defp assert_woken(agent_id, needle) do
    assert_receive {:work_turn_requested, ^agent_id, _ref, message}, 2_000

    assert message =~ needle,
           "the holder was offered a turn, but not told which task to resume: #{message}"

    message
  end

  test "answering a question releases the agent's task and wakes it to resume", ctx do
    task = active_task(ctx.scope, ctx.agent)
    request = ask(ctx.scope, ctx.agent, task)

    {:ok, _} = answer(request)

    refute waiting?(task(Agent, ctx.agent.id, task.id)), "the answer left its task waiting"

    assert_woken(
      ctx.agent.id,
      "Your blocker question #{request.id} was answered; resume task #{task.id} " <>
        "(`bdd_specs_passing`) with `start_task`"
    )
  end

  test "answering a question releases a session's task waiting on it", ctx do
    session = session_fixture(ctx.scope)
    task = active_task(ctx.scope, session)

    {:ok, request} =
      Notifications.create_question_request(ctx.scope.user.id, %{
        "title" => "Which way",
        "questions" => [%{"question" => "Which way?", "options" => []}]
      })

    {:ok, _} = TaskOwner.block_task(ctx.scope, session, task.id, :question, request.id)

    {:ok, _} = answer(request)

    refute waiting?(task(Session, session.id, task.id)),
           "a session's task stayed blocked on an answered question"
  end

  test "a denied tap-out releases its task and wakes the holder to resume it", ctx do
    task = active_task(ctx.scope, ctx.agent)
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, task.id)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "deny", "keep at it")

    released = task(Agent, ctx.agent.id, task.id)
    assert released.status == :blocked, "a denied tap-out resumes; it never cancels"
    refute waiting?(released), "the denial left its task waiting"

    message =
      assert_woken(
        ctx.agent.id,
        "Your blocker tap_out #{request.id} was denied; resume task #{task.id}"
      )

    assert message =~ "keep at it", "the reason for the denial was dropped"
  end

  test "an approved tap-out leaves no blocked task behind and wakes nobody", ctx do
    task = active_task(ctx.scope, ctx.agent)
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, task.id)

    {:ok, _} = Notifications.resolve_permission_request(request.id, "allow")

    refute task(Agent, ctx.agent.id, task.id).status == :blocked
    refute_receive {:work_turn_requested, _, _, _}, 300
  end

  test "a dismissed tap-out releases its task rather than stranding it", ctx do
    task = active_task(ctx.scope, ctx.agent)
    {:ok, request} = Notifications.request_agent_tap_out(ctx.scope, ctx.agent.id, task.id)

    {:ok, _} = Notifications.dismiss_permission_request(request.id)

    released = task(Agent, ctx.agent.id, task.id)
    assert released.status == :blocked, "a dismissed tap-out must not cancel the task"
    refute waiting?(released), "nobody deciding left the task blocked forever"
    assert_woken(ctx.agent.id, "Your blocker tap_out #{request.id} was dismissed; resume")
  end

  test "a question answered for another agent's task wakes that agent, not the answerer",
       ctx do
    main = agent(ctx.scope, ctx.copy, "main")
    task = active_task(ctx.scope, ctx.agent)

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        main.id,
        %{
          "title" => "Which way",
          "questions" => [%{"question" => "Which way?", "options" => []}]
        },
        nil
      )

    {:ok, _} = TaskOwner.block_task(ctx.scope, ctx.agent, task.id, :question, request.id)

    {:ok, _} = answer(request, answered_by: "main_agent")

    refute waiting?(task(Agent, ctx.agent.id, task.id))
    assert_woken(ctx.agent.id, "resume task #{task.id}")
    main_id = main.id
    refute_receive {:work_turn_requested, ^main_id, _, _}, 300
  end

  test "every task waiting on the blocker is released, not just the first", ctx do
    blocker_id = Ecto.UUID.generate()

    {:ok, agent} =
      Enum.reduce(1..8, {:ok, ctx.agent}, fn n, {:ok, agent} ->
        agent
        |> Agent.add_task(%{
          status: :blocked,
          requirement_name: "bdd_specs_passing_#{n}",
          blocked_at: DateTime.utc_now(),
          blocker_type: :question,
          blocker_id: blocker_id
        })
        |> Repo.update()
      end)

    {:ok, released} = TaskOwner.blocker_resolved(:question, blocker_id, :answered)

    assert released == 8
    assert agent |> TaskOwner.blocked_tasks() |> length() == 8
    refute Enum.any?(TaskOwner.tasks(Repo.get!(Agent, agent.id)), &waiting?/1)

    message = assert_woken(agent.id, "Your blocker question #{blocker_id} was answered")
    for task <- agent.tasks, do: assert(message =~ task.id)
  end
end
