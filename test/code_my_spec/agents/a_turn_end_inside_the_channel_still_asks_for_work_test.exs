defmodule CodeMySpec.Agents.ATurnEndInsideTheChannelStillAsksForWorkTest do
  @moduledoc """
  104bcb23: `StopDecision.deliver/3` runs inside the harness channel at turn end,
  and its turn request is a call back into that channel. The transport refuses
  a call to itself, so a continuous agent that finished a task sat idle with
  work waiting — 79 refusals in one day.

  Asserted as the property the transport needs: the request comes from some
  process other than the one delivering the decision.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  # Stands in for the harness transport and says which process asked.
  defmodule CallerReportingTransport do
    def request_work_turn(_copy_id, agent, _ref, _prompt, _timeout) do
      send(:persistent_term.get({__MODULE__, :test}), {:request_work_turn, agent.id, self()})
      {:ok, :started}
    end

    def dispatch_message(_copy_id, _agent, _ref, _message, _timeout), do: {:ok, :started}
  end

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, CallerReportingTransport)
    :persistent_term.put({CallerReportingTransport, :test}, self())

    on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, previous)
      :persistent_term.erase({CallerReportingTransport, :test})
    end)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/turn-end-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    Map.put(ctx, :agent, agent)
  end

  test "the next turn is requested off the process that delivered the decision", ctx do
    :ok = StopDecision.deliver(ctx.scope, ctx.agent)

    agent_id = ctx.agent.id
    assert_receive {:request_work_turn, ^agent_id, caller}, 2_000

    refute caller == self(),
           "the turn was requested from the delivering process, which at turn end is the " <>
             "harness channel — the transport refuses that as a call to itself"
  end
end
