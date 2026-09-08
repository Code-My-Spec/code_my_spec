defmodule CodeMySpec.Agents.TheNudgeStopsRepeatingTest do
  @moduledoc """
  An agent told the same thing five times is not told it a sixth.

  The stop decision has had this guard since R8: `stuck?/2` counts identical
  blocks and goes quiet. The nudge beside it did not, and that asymmetry is what
  turned it into noise — the menu falls silent when it repeats, and the nudge
  keeps going out alone. An agent holding a task it *cannot* close is then
  nudged on every stop, forever, and it is the only thing being said to it.

  Measured 2026-09-08 across eight hours on one coding agent: 251 nudges against
  85 menus. The task was `issues_resolved`, held against issues that lived in
  another repository. John: "I keep seeing this ... or some variation hitting
  the agent. Why?"

  Keyed on the task id, so a different task says it again. What stops is
  repeating one instruction at an agent that has already heard it and not acted.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpecTest.RecordingAgentTransport

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

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
        continuous: false,
        working_copy: "/tmp/nudge-repeat-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    # The counters live in `:persistent_term` keyed by agent id. A fresh agent
    # per test keeps them independent; erasing on exit keeps the table from
    # growing across a run.
    on_exit(fn ->
      :persistent_term.erase({StopDecision, :nudge, agent.id})
      :persistent_term.erase({StopDecision, :decision, agent.id})
    end)

    %{scope: scope, agent: agent}
  end

  # On the struct, the way the sibling nudge test does it: `StopDecision` takes
  # an `%Agent{}` and `Agent.active_task/1` reads the embed off it, so this is
  # the same value production sees.
  #
  # `continuous: false` in the setup above is load-bearing. A continuous agent
  # is handed the menu through the `:continuing` branch, which carries the task
  # id — so `already_said?` holds and the nudge never runs. The unguarded nudge
  # only reaches an agent whose decision does not name its task, which is the
  # shape John was watching.
  defp holding(agent, requirement, task_id) do
    task = %CodeMySpec.Sessions.Task{
      id: task_id,
      status: :active,
      requirement_name: requirement,
      started_at: DateTime.utc_now()
    }

    %{agent | tasks: [task]}
  end

  defp drain(acc \\ []) do
    receive do
      {:agent_dispatch, _id, _ref, message} -> drain([message | acc])
      {:agent_message, _id, message} -> drain([message | acc])
    after
      200 -> acc
    end
  end

  test "the same open task stops being announced once the agent has heard it", ctx do
    task_id = Ecto.UUID.generate()
    held = holding(ctx.agent, "issues_resolved", task_id)

    for _ <- 1..9, do: StopDecision.deliver(ctx.scope, held, [])

    nudges = Enum.count(drain(), &String.contains?(&1, task_id))

    assert nudges > 0, "an agent must hear about its open task at least once"

    assert nudges <= 6,
           "nine stops delivered the same instruction #{nudges} times; the decision " <>
             "beside it goes quiet after five and this has to as well"
  end

  test "going quiet on one task does not silence the next", ctx do
    first = Ecto.UUID.generate()

    for _ <- 1..9,
        do: StopDecision.deliver(ctx.scope, holding(ctx.agent, "issues_resolved", first), [])

    drain()

    second = Ecto.UUID.generate()
    StopDecision.deliver(ctx.scope, holding(ctx.agent, "bdd_specs_passing", second), [])

    assert Enum.any?(drain(), &String.contains?(&1, second)),
           "a new task is a new instruction and must be delivered"
  end

  # The decision's own counter must not be spent by the nudge, or the menu would
  # go quiet early on an agent that is being nudged about something else.
  test "the nudge's counter is separate from the decision's", ctx do
    task_id = Ecto.UUID.generate()

    for _ <- 1..9,
        do: StopDecision.deliver(ctx.scope, holding(ctx.agent, "issues_resolved", task_id), [])

    drain()

    assert :persistent_term.get({StopDecision, :nudge, ctx.agent.id}, nil),
           "the nudge counts in its own slot"
  end
end
