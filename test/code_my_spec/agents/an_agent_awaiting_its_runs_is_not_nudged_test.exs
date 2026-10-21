defmodule CodeMySpec.Agents.AnAgentAwaitingItsRunsIsNotNudgedTest do
  @moduledoc """
  A continuous agent holding a task that started analyzer runs and stopped is
  not handed the turn-end continuation while those runs are in flight.
  `AnalysisReport` messages it when each one lands or fails; the continuation
  only bought "same nudge, still waiting" turns — 5 to 27 an hour on
  metric_flow's coding agent, 2026-09-27.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)

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
        working_copy: "/tmp/awaiting-runs-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    on_exit(fn -> :persistent_term.erase({StopDecision, :continuing, agent.id}) end)

    task = %CodeMySpec.Agents.Agent.Task{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "qa_complete",
      started_at: DateTime.utc_now()
    }

    %{scope: %{scope | active_working_copy_id: copy.id}, agent: %{agent | tasks: [task]}}
  end

  defp run_requested_by(scope, agent_id, status) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: "spex",
        kind: :full,
        status: status,
        requested_by: %{kind: "mcp_tool", tool: "start_analysis", agent_id: agent_id}
      })

    run
  end

  defp continuations, do: Enum.count(dispatched(), &(&1 =~ "loop is still running"))

  defp dispatched do
    receive do
      {:agent_dispatch, _id, _ref, message} -> [message | dispatched()]
    after
      200 -> []
    end
  end

  test "its own run still running holds the continuation back", ctx do
    run_requested_by(ctx.scope, ctx.agent.id, :running)

    StopDecision.deliver(ctx.scope, ctx.agent, [])

    assert continuations() == 0
  end

  # cc578c21: a promote's restart killed the coder's spex run, and the coder
  # was nudged "Your turn is done" six times in a minute with nothing to act
  # on. The run is re-dispatched when the harness rejoins, so it is still
  # being waited on.
  test "its own run killed by a restart, not yet run again, holds it back too", ctx do
    run_requested_by(ctx.scope, ctx.agent.id, :running)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)
    _told_nothing = dispatched()

    StopDecision.deliver(ctx.scope, ctx.agent, [])

    assert continuations() == 0
  end

  test "its own run that genuinely failed does not", ctx do
    ctx.scope
    |> run_requested_by(ctx.agent.id, :running)
    |> Reconciler.fail(:analyzer_crashed)

    StopDecision.deliver(ctx.scope, ctx.agent, [])

    # Not held back as awaiting: it is told the run failed — the answer to the
    # run it started — and the continuation waits behind that turn.
    assert Enum.any?(dispatched(), &(&1 =~ "failed without a result"))
  end

  test "with nothing of its own in flight it is prompted as before", ctx do
    run_requested_by(ctx.scope, ctx.agent.id, :completed)
    run_requested_by(ctx.scope, Ecto.UUID.generate(), :running)

    StopDecision.deliver(ctx.scope, ctx.agent, [])

    assert continuations() == 1
  end
end
