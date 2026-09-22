defmodule CodeMySpec.Agents.AHeldTaskIsRemindedNotAbandonedTest do
  @moduledoc """
  An agent holding a claim with no turn in flight is asked to dispose of it.

  `Work.runnable_state?/1` skips an agent with an open task, which is right — it
  is not offered *new* work while it holds a claim. The consequence was that
  nothing reached it at all: not a graph change, not the reconnect sweep, not a
  denied tap-out, not the main agent's cadence. An agent that ended a turn still
  holding a task was unreachable until a person messaged it.

  Measured on the math project 2026-09-22, three times in one session — 22, 25
  and 26 minutes, each ended by hand. It is the last thing that stopped a
  cold-start story completing unattended: coding asked for a spex run, the run
  came back green, nothing told it, and it sat holding `bdd_specs_passing`.

  ## Why this cannot loop

  The fleet has two live nudge-loop defects (`59c97e41`, `ce3471ef`) and both
  re-fire on every *stop*, which is what an agent does after every turn. Nothing
  here fires on a stop. `Work.consider_*`'s callers are a harness join, a denied
  tap-out, continuous being switched on, a graph change, and the cadence — an
  agent reminded, turning, and stopping without disposing triggers none of them.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
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

    %{scope: %{scope | active_working_copy_id: copy.id}, copy: copy}
  end

  defp agent_holding(ctx, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/held-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    {:ok, agent} =
      agent
      |> CodeMySpec.Agents.Agent.add_task(%CodeMySpec.Sessions.Task{
        id: Ecto.UUID.generate(),
        status: :active,
        requirement_name: "bdd_specs_passing",
        started_at: DateTime.utc_now()
      })
      |> CodeMySpec.Repo.update()

    {:ok, agent} = AgentsRepository.update_agent(ctx.scope, agent, attrs)

    agent
  end

  test "an idle agent holding a task is reminded of it", ctx do
    agent = agent_holding(ctx, %{})

    assert {:ok, :reminded} = Work.request_turn_if_runnable(ctx.scope, agent, :test)

    assert_receive {:agent_dispatch, id, _ref, message}, 2_000
    assert id == agent.id

    assert message =~ "task",
           """
           An agent holding a claim was skipped in silence.

           Nothing else reaches it — `runnable_state?/1` excludes it from every
           wake path — so silence here means a person has to notice.
           """
  end

  # The guard exists to protect a turn in flight, and that must still hold.
  test "an agent mid-turn is left alone", ctx do
    agent = agent_holding(ctx, %{turn_started_at: DateTime.utc_now()})

    refute match?({:ok, :reminded}, Work.request_turn_if_runnable(ctx.scope, agent, :test))

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end
end
