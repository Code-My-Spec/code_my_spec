defmodule CodeMySpec.Agents.AFailedRunReachesItsRequesterFromTheChannelTest do
  @moduledoc """
  A run failed on channel death or join is announced from inside the harness
  channel, and delivering it is a call back into that channel. The transport
  refused it as `:would_deadlock`, so metric_flow's QA agent waited 45 minutes
  on exunit and spex runs a restart had already killed (2026-09-27).

  Asserted as the property the transport needs: the delivery comes from some
  process other than the one announcing the failure.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpecTest.AgentPresence

  defmodule CallerReportingTransport do
    def dispatch_message(_copy_id, agent, _ref, message, _timeout) do
      send(:persistent_term.get({__MODULE__, :test}), {:dispatched, agent.id, message, self()})
      {:ok, :started}
    end
  end

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, CallerReportingTransport)
    :persistent_term.put({CallerReportingTransport, :test}, self())

    on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, previous)
      :persistent_term.erase({CallerReportingTransport, :test})
    end)

    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        status: :running,
        working_copy: "/tmp/failed-run-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  test "the requester hears about the failure off the announcing process", ctx do
    :ok =
      AnalysisReport.deliver_failure(ctx.scope, "exunit", "the harness restarted", ctx.agent.id)

    agent_id = ctx.agent.id
    assert_receive {:dispatched, ^agent_id, message, caller}, 2_000
    assert message =~ "exunit"

    refute caller == self(),
           "the failure was delivered from the announcing process, which on channel death " <>
             "is the harness channel — the transport refuses that as a call to itself"
  end
end
