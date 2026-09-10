defmodule CodeMySpec.Agents.TheNudgeReachesTheAgentTest do
  @moduledoc """
  An agent nudged about its open task is nudged, not written about.

  `nudge_open_task/2` called `record_orchestrator_action/3` and returned. That
  writes the line into the conversation and sends nothing — so the nudge
  rendered in the transcript, read as an instruction that had been given, and
  reached nobody. Every stop with an open task produced one, and the agent
  never saw a single one.

  John, watching a stop on 2026-09-07: "I'm also continuing to see this message
  from the orchestrator, which I think is a total red herring and that it's not
  even being delivered to the agent."

  The criterion for this behaviour asserts against
  `Fixtures.orchestrator_actions/2`, which reads the transcript — so it passed
  the whole time. "Told" has to mean delivered, and the transcript is a copy of
  what was said rather than evidence that anyone heard it.

  The external path never had the bug: there the nudge is part of the stop
  hook's own response, and a response is delivered by definition. Only an agent
  we run needed the dispatch.
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

    %{scope: scope, agent: agent}
  end

  # On the struct rather than through a write. `StopDecision.decide/2` takes an
  # `%Agent{}` and `Agent.active_task/1` reads the embed off it, so this is the
  # same value the production path sees — and the test says what it depends on
  # instead of depending on a fixture that puts the task somewhere else.
  defp with_open_task(agent) do
    task = %CodeMySpec.Sessions.Task{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "bdd_specs_passing",
      started_at: DateTime.utc_now()
    }

    {%{agent | tasks: [task]}, task}
  end

  # Nothing blocking, so the task wins the directive and the menu says the whole
  # thing itself. One message, not two.
  test "when the menu carries the task, the nudge does not repeat it", ctx do
    {agent, task} = with_open_task(ctx.agent)

    StopDecision.deliver(ctx.scope, agent, [])

    carrying = Enum.filter(drain([]), &String.contains?(&1, task.id))

    assert length(carrying) == 1, """
    The agent was told the same thing twice in one stop. The menu's task clause
    already names the requirement and the id; a nudge after it is the same
    instruction again, and two copies of one instruction read as two tasks.

    #{inspect(carrying, limit: :infinity, printable_limit: 2000)}
    """
  end

  # The case John was looking at: problems outrank the task, so the menu leads
  # with `list_problems` and the task is a tally line — "Also live: 3 open
  # tasks" — naming neither the requirement nor the id. Then the nudge is the
  # only thing carrying it, and it has to arrive.
  test "when problems lead the menu, the nudge still delivers the id", ctx do
    {agent, task} = with_open_task(ctx.agent)
    problem_fixture(ctx.scope, %{severity: :error, source: "compiler"})

    StopDecision.deliver(ctx.scope, agent, [])

    messages = drain([])

    assert Enum.any?(messages, &String.contains?(&1, task.id)), """
    The menu led with problems, so nothing it said named the task id — and the
    one message that does was recorded to the transcript and never sent. That is
    a stop where the agent is told about 48 problems and never told what it is
    still holding.

    #{inspect(messages, limit: :infinity, printable_limit: 2000)}
    """
  end

  test "an agent with nothing open is not nudged about nothing", ctx do
    StopDecision.deliver(ctx.scope, ctx.agent, [])

    refute Enum.any?(drain([]), &(&1 =~ "still open")),
           "an agent holding no task was told to close one"
  end

  # The report this exists for: an agent calls tap_out, stops, and — in the
  # same breath — is told "you stopped with X still open, close it yourself".
  # `decide_with_key/3` correctly silences the menu for an agent awaiting an
  # answer, but `nudge_open_task/3` never checked that guard at all — it only
  # ever asked whether the (silenced) decision text happened to already name
  # the task, which for a silenced `nil` decision is never true. So the one
  # message that must land right after tap_out — "stopping and waiting" —
  # arrived paired with its opposite: keep going.
  test "an agent awaiting an answer is not also nudged about its open task", ctx do
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
           An agent waiting on a tap-out decision was sent something anyway — most
           likely the open-task nudge, which does not know the decision was silenced
           on purpose rather than because there was nothing to say.

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
