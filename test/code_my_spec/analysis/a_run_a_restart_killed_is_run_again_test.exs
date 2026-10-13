defmodule CodeMySpec.Analysis.ARunARestartKilledIsRunAgainTest do
  @moduledoc """
  A requested run that dies because its harness went away is run again when a
  harness rejoins the copy, and its answer reaches the agent that asked.

  metric_flow, 2026-09-30 (cc578c21): spex run 53537 was failed at 14:00:33 by
  a promote's restart. The failure was announced while the harness was gone, so
  nobody heard it, nothing re-ran it, and the coder answered "Your turn is done"
  nudges until someone queued the run again by hand 16 minutes later.
  """
  use CodeMySpecTest.DataCase, async: false

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

  test "a run a disconnect killed is re-dispatched on rejoin and answers its requester", ctx do
    killed = requested_run(ctx.scope, ctx.agent)

    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    # Not "your run failed, start it again": it is about to be started again,
    # and telling the agent to do it too queues the same sweep twice.
    refute_receive {:agent_dispatch, _id, _ref, _message}, 100

    rejoin(ctx.scope)

    assert_receive {:run_analysis, [%{"run_id" => rerun_id, "source" => "compiler"}]}
    assert rerun_id != killed.id

    rerun = RunsRepository.get_running_run(ctx.scope, rerun_id)
    assert rerun.requested_by["agent_id"] == ctx.agent.id

    Analysis.record_remote_result(ctx.scope, clean_compile(rerun_id))

    assert_receive {:agent_dispatch, id, _ref, _message}
    assert id == ctx.agent.id
  end

  test "a run a server restart killed is re-dispatched once, not on every join", ctx do
    requested_run(ctx.scope, ctx.agent)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, @restart)

    rejoin(ctx.scope)
    assert_receive {:run_analysis, [_]}

    Analysis.resume_orphaned(ctx.scope, [])
    refute_receive {:run_analysis, _}, 100
  end

  test "a run the returning harness still holds is reopened, not run twice", ctx do
    held = requested_run(ctx.scope, ctx.agent)
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
    {:ok, _run} = RunsRepository.start_run(ctx.scope, %{source: "compiler", kind: :full})
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    rejoin(ctx.scope)

    refute_receive {:run_analysis, _}, 100
  end

  test "a run killed on every attempt stops being re-run and its requester is told", ctx do
    requested_run(ctx.scope, ctx.agent, %{"redispatches" => 3})
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    rejoin(ctx.scope)

    refute_receive {:run_analysis, _}, 100
    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == ctx.agent.id
    assert message =~ "harness_disconnected"
    refute Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end

  test "the agent is still awaiting a killed run until the rejoin settles it", ctx do
    requested_run(ctx.scope, ctx.agent)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    assert Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end

  test "a genuinely failed run is not awaited", ctx do
    ctx.scope |> requested_run(ctx.agent) |> Reconciler.fail(:analyzer_crashed)

    refute Analysis.awaiting_runs?(ctx.scope, ctx.copy.id, ctx.agent.id)
  end
end
