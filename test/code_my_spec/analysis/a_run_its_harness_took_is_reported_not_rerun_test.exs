defmodule CodeMySpec.Analysis.ARunItsHarnessTookIsReportedNotRerunTest do
  @moduledoc """
  A requested run that dies because its harness went away is reported to the
  agent that asked when a harness rejoins the copy, and is not run again
  (story 1142): whoever asked decides whether to ask again.

  metric_flow, 2026-09-30 (cc578c21): spex run 53537 was failed at 14:00:33 by
  a promote's restart, announced while the harness was gone, so nobody heard
  it. The answer now waits for the rejoin, when somebody can hear it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  @restart "the shared dev server was restarted at 2026-09-30T14:00:33Z — this run was killed by that restart"

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/rerun-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    # Present: the answer is delivered to an agent whose process is alive.
    AgentPresence.present(agent)

    %{scope: scope, agent: agent, copy: copy}
  end

  defp requested_run(scope, agent, extra \\ %{}) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: "compiler",
        kind: :full,
        args: %{"args" => []},
        requested_by:
          Map.merge(
            %{"kind" => "mcp_tool", "tool" => "start_analysis", "agent_id" => agent.id},
            extra
          )
      })

    run
  end

  defp begun_run(scope, agent) do
    run = requested_run(scope, agent)
    RunsRepository.record_tree(run, %{:began_at => DateTime.utc_now()})
  end

  # This process stands in for the rejoined harness's channel: a dispatch is
  # `send(channel, {:run_analysis, runs})`.
  defp rejoin(scope, claimed \\ []) do
    :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)
    Analysis.resume_orphaned(scope, claimed)
  end

  defp clean_compile(run_id) do
    %{
      "run_id" => run_id,
      "source" => "compiler",
      "status" => "ok",
      "result" => %{"exit_status" => 0, "diagnostics" => []}
    }
  end

  test "a run a disconnect killed is reported on rejoin and not run again", ctx do
    begun_run(ctx.scope, ctx.agent)

    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    # Not while the harness is gone: nobody could hear it.
    refute_receive {:agent_dispatch, _id, _ref, _message}, 100

    rejoin(ctx.scope)

    refute_receive {:run_analysis, _}, 100
    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == ctx.agent.id
    assert message =~ "harness went away"
    assert message =~ "not being run again"
    refute Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end

  test "a run a server restart killed is reported once, not on every join", ctx do
    begun_run(ctx.scope, ctx.agent)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, @restart)

    rejoin(ctx.scope)
    assert_receive {:agent_dispatch, _id, _ref, _message}

    Analysis.resume_orphaned(ctx.scope, [])
    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
    refute_receive {:run_analysis, _}, 100
  end

  test "a run the returning harness still holds is reopened, not run twice", ctx do
    held = begun_run(ctx.scope, ctx.agent)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, @restart)

    rejoin(ctx.scope, [held.id])

    refute_receive {:run_analysis, _}, 100
    assert %{status: :running} = RunsRepository.get_running_run(ctx.scope, held.id)

    Analysis.record_remote_result(ctx.scope, clean_compile(held.id))
    assert_receive {:agent_dispatch, _id, _ref, _message}
  end

  test "a run that genuinely failed is not re-dispatched", ctx do
    ctx.scope |> requested_run(ctx.agent) |> Reconciler.fail(:analyzer_crashed)
    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "analyzer_crashed"

    rejoin(ctx.scope)

    refute_receive {:run_analysis, _}, 100
  end

  test "a run nobody requested is not started again", ctx do
    {:ok, run} = RunsRepository.start_run(ctx.scope, %{source: "compiler", kind: :full})
    RunsRepository.record_tree(run, %{began_at: DateTime.utc_now()})
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    rejoin(ctx.scope)

    refute_receive {:run_analysis, _}, 100
  end

  test "the agent is still awaiting a killed run until the rejoin settles it", ctx do
    begun_run(ctx.scope, ctx.agent)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    assert Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end

  test "a genuinely failed run is not awaited", ctx do
    ctx.scope |> requested_run(ctx.agent) |> Reconciler.fail(:analyzer_crashed)

    refute Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end

  test "server boot leaves a remote run open for its returning harness", ctx do
    held = begun_run(ctx.scope, ctx.agent)

    assert {:ok, 0} = Analysis.settle_stranded_runs()
    assert %{status: :running} = RunsRepository.get_running_run(ctx.scope, held.id)

    rejoin(ctx.scope, [held.id])
    assert :ok = Analysis.reconcile_rejoined(ctx.scope, [held.id])
    refute_receive {:run_analysis, _}, 100

    assert {:ok, %{id: id, status: :completed}} =
             Analysis.record_remote_result(ctx.scope, clean_compile(held.id))

    assert id == held.id
  end

  test "a queued run survives disconnect and restart until re-admission", ctx do
    queued = requested_run(ctx.scope, ctx.agent)
    assert queued.began_at == nil

    assert {:ok, 0} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    assert %{status: :running, orphaned: true, stats: nil, began_at: nil} =
             RunsRepository.get_run_in_project(ctx.scope, queued.id)

    assert RunsRepository.latest_full_run(ctx.scope, "compiler") == nil
    assert Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)

    assert {:ok, 0} = Analysis.settle_stranded_runs()
    rejoin(ctx.scope)
    assert :ok = Analysis.reconcile_rejoined(ctx.scope, [])

    assert_receive {:run_analysis, [%{"run_id" => id, "source" => "compiler"}]}
    assert id == queued.id

    assert %{status: :running, orphaned: false, stats: nil} =
             RunsRepository.get_run_in_project(ctx.scope, id)

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100

    assert {:ok, %{id: ^id, status: :completed}} =
             Analysis.record_remote_result(ctx.scope, clean_compile(id))
  end

  test "a queued run lost by the old channel is readmitted with its original id", ctx do
    queued = requested_run(ctx.scope, ctx.agent)
    assert {:ok, 0} = Analysis.settle_stranded_runs()
    rejoin(ctx.scope)

    assert :ok = Analysis.reconcile_rejoined(ctx.scope, [])
    assert_receive {:run_analysis, [%{"run_id" => id, "source" => "compiler"}]}
    assert id == queued.id
    assert %{status: :running} = RunsRepository.get_running_run(ctx.scope, queued.id)
  end

  test "a queued run whose harness never rejoins is not counted as failed", ctx do
    queued = requested_run(ctx.scope, ctx.agent)
    assert {:ok, 0} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    cutoff = DateTime.add(DateTime.utc_now(), 1, :second)
    assert :ok = Analysis.abandon_unclaimed_after_restart(cutoff)

    assert %{status: :abandoned, stats: %{"error" => reason}} =
             RunsRepository.get_run_in_project(ctx.scope, queued.id)

    assert reason =~ "did not rejoin"
    assert RunsRepository.latest_full_run(ctx.scope, "compiler") == nil
    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "not run"
  end

  test "a harness that never rejoins leaves an abandoned run, not a failed result", ctx do
    run = begun_run(ctx.scope, ctx.agent)
    cutoff = DateTime.add(DateTime.utc_now(), 1, :second)

    assert :ok = Analysis.abandon_unclaimed_after_restart(cutoff)

    assert %{status: :abandoned, orphaned: true, stats: %{"error" => reason}} =
             RunsRepository.get_run_in_project(ctx.scope, run.id)

    assert reason =~ "did not rejoin"
    assert RunsRepository.latest_full_run(ctx.scope, "compiler") == nil
    assert_receive {:agent_dispatch, _id, _ref, message}
    assert message =~ "not run"
    assert message =~ "did not rejoin"
  end
end
