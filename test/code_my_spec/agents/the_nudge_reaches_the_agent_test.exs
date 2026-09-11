defmodule CodeMySpec.Agents.TheNudgeReachesTheAgentTest do
  @moduledoc """
  An agent holding an open task hears about it through the menu, once.

  There used to be a second, separate nudge beside the decision — its own
  function, its own message, its own repeat-suppression counter. It existed
  because the menu's own `:task` directive sometimes did not carry enough
  (dropped to a tally line with no id when problems led, or never said why a
  requirement was still open at all), so a duplicate message was built to
  cover the gap.

  John: "non-continuous agents shouldn't get the menu or a nudge at all ...
  this is the purpose of the stop hook menu, and the open task nudge is
  duplicative." The fix was not a second message that repeats what the menu
  already said — it was making the menu say the whole thing itself: the
  obstacle text moved into `Menu.directive`'s `:task` clause, and the tally
  points at `list_tasks` when a task is present but not leading. One
  mechanism, one place to throttle it.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Notifications
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
        role: "coding",
        continuous: true,
        working_copy: "/tmp/nudge-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn ->
      :persistent_term.erase({StopDecision, :continuing, agent.id})
      :persistent_term.erase({StopDecision, :decision, agent.id})
    end)

    %{scope: scope, agent: agent}
  end

  # On the struct rather than through a write. `StopDecision.decide/2` takes an
  # `%Agent{}` and `Agent.active_task/1` reads the embed off it, so this is the
  # same value the production path sees.
  defp with_open_task(agent) do
    task = %CodeMySpec.Sessions.Task{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "bdd_specs_passing",
      started_at: DateTime.utc_now()
    }

    {%{agent | tasks: [task]}, task}
  end

  test "an open task is named once, by the menu, with its id", ctx do
    {agent, task} = with_open_task(ctx.agent)

    StopDecision.deliver(ctx.scope, agent, [])

    carrying = Enum.filter(drain([]), &String.contains?(&1, task.id))

    assert length(carrying) == 1, """
    The agent should hear about its open task exactly once — from the menu,
    which already names the requirement and the id. Two copies of one
    instruction read as two tasks.

    #{inspect(carrying, limit: :infinity, printable_limit: 2000)}
    """
  end

  # Watched live on 2026-09-10: a coding agent nudged every 90 seconds about
  # `code_on_running_copy` while the gate was refusing on "uncommitted changes
  # — commit them". The message said what was open and never what was holding
  # it, so the agent spent the loop re-reporting an unrelated credo
  # notification, which was the only concrete thing it had.
  test "the menu says why the requirement is still open", ctx do
    # A node the graph actually holds. In production a task exists *because* the
    # graph emitted its requirement, so the node is always there — but a story
    # invented in a test has never been through it, and the lookup correctly
    # finds nothing.
    task = %CodeMySpec.Sessions.Task{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "technical_strategy",
      project_id: ctx.scope.active_project_id,
      started_at: DateTime.utc_now()
    }

    agent = %{ctx.agent | tasks: [task]}

    StopDecision.deliver(ctx.scope, agent, [])

    message =
      drain([])
      |> Enum.find(&String.contains?(&1, "open task"))

    assert message, "no message naming the open task was delivered at all"

    assert String.contains?(message, "It is open because:"), """
    The message named the requirement and not the obstacle, which is the shape
    that livelocked an agent: told that something is open, never told what is
    holding it, and given no way to find out.

    #{message}
    """
  end

  # The case John was looking at: problems outrank the task, so the menu leads
  # with `list_problems` and the task is a tally line — "Also live: an open
  # task" — naming neither the requirement nor the id. `evaluate_task` needs
  # the id, so the tally has to point somewhere it can be found instead.
  test "when problems lead the menu, the tally still points at the task's id", ctx do
    {agent, _task} = with_open_task(ctx.agent)
    problem_fixture(ctx.scope, %{severity: :error, source: "compiler"})

    StopDecision.deliver(ctx.scope, agent, [])

    messages = drain([])

    assert Enum.any?(messages, &String.contains?(&1, "list_tasks")), """
    The menu led with problems, so the task was a tally line with no id in it —
    and nothing pointed at where the id could be found. That is a stop where
    the agent is told about a problem and never told how to act on the task it
    is still holding.

    #{inspect(messages, limit: :infinity, printable_limit: 2000)}
    """
  end

  test "an agent with nothing open is not told to close anything", ctx do
    StopDecision.deliver(ctx.scope, ctx.agent, [])

    refute Enum.any?(drain([]), &(&1 =~ "open task")),
           "an agent holding no task was told to close one"
  end

  test "an agent awaiting an answer is not also told about its open task", ctx do
    {agent, task} = with_open_task(ctx.agent)

    {:ok, _request} =
      Notifications.create_permission_request(ctx.scope.user.id, %{
        "agent_id" => agent.id,
        "tool_name" => "tap_out",
        "tool_input" => %{"agent_id" => agent.id}
      })

    StopDecision.deliver(ctx.scope, agent, [])

    messages = drain([])

    assert messages == [],
           """
           An agent waiting on a tap-out decision was sent something anyway.

           #{inspect(messages, limit: :infinity, printable_limit: 2000)}
           """

    refute Enum.any?(messages, &String.contains?(&1, task.id)),
           "told to close the task it just asked to stop holding"
  end

  defp drain(acc) do
    receive do
      {:agent_dispatch, _id, _ref, message} -> drain([message | acc])
    after
      500 -> acc
    end
  end
end
