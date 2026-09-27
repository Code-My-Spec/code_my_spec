defmodule CodeMySpec.Analysis.AFailedRunAnswersItsRequesterTest do
  @moduledoc """
  A requested run answers whatever happens to it, including failing.

  metric_flow, 2026-09-27: the coding agent's spex run 52672 was killed by a
  server restart. Only a completed run reported back, so the agent, waiting on
  it before promoting, would have waited forever.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
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

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/failed-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  defp run(scope, requested_by) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: "spex", kind: :full, requested_by: requested_by})

    run
  end

  test "a run that fails tells the agent that requested it", ctx do
    run = run(ctx.scope, %{"agent_id" => ctx.agent.id})

    Reconciler.fail(run, :timeout)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == ctx.agent.id
    assert message =~ "spex run failed"
    assert message =~ ":timeout"
    assert message =~ "start the spex run again"
  end

  test "a run closed by a server restart tells the agent that requested it", ctx do
    run(ctx.scope, %{"agent_id" => ctx.agent.id})

    reason = "the shared dev server was restarted — this run was killed by that restart"
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, reason)

    assert_receive {:agent_dispatch, id, _ref, message}
    assert id == ctx.agent.id
    assert message =~ "killed by that restart"
  end

  test "a failed run nobody requested stays silent", ctx do
    Reconciler.fail(run(ctx.scope, nil), :timeout)
    run(ctx.scope, nil)
    {:ok, 1} = Analysis.fail_in_flight(ctx.scope, :harness_disconnected)

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end

  test "a Claude Code subagent id is not an agent to tell", ctx do
    Reconciler.fail(run(ctx.scope, %{"agent_id" => "af6cbaec65372da7a"}), :timeout)

    refute_receive {:agent_dispatch, _id, _ref, _message}, 100
  end
end
