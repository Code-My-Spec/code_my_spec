defmodule CodeMySpec.Agents.Offers.AnOfferWhoseDeliveryFailedIsMadeAgainTest do
  @moduledoc """
  A turn request that failed is not a refusal.

  `Work.request_turn_if_runnable/4` records `undelivered` and releases the
  reservation when the transport cannot reach the machine — a harness that is
  still coming up after a restart, or a machine briefly unreachable. It then
  also stamped the agent's decline streak, which is the impasse this test
  names: `already_declined?/3` read that stamp as "the agent said no", so the
  work went quiet for the whole decline window and the agent was never offered
  it again once it *was* reachable. Continuous agents sat idle after restarts
  for exactly this reason.

  A delivery failure costs a retry, not a rung of the ladder.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.UnreachableMachine
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp unreachable do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, UnreachableMachine)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    :ok
  end

  defp reachable do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, CodeMySpecTest.InProcessAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    :ok
  end

  defp agent(scope, attrs \\ %{}) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: "coding",
            continuous: true,
            status: :running,
            working_copy: "/tmp/redelivered-#{System.unique_integer([:positive])}",
            working_copy_id: scope.active_working_copy_id
          },
          attrs
        )
      )

    AgentPresence.present(agent)

    {:ok, _} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn -> :persistent_term.erase({StopDecision, :continuing, agent.id}) end)
    agent
  end

  test "a work offer whose delivery failed is made again once the machine is reachable", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    agent = agent(ctx.scope)

    unreachable()

    assert {:error, :harness_not_connected} =
             Work.request_turn_if_runnable(ctx.scope, agent, :test)

    # The failure is not a refusal: nothing was declined.
    {:ok, after_failure} = AgentsRepository.fetch_agent(ctx.scope, agent.id)
    assert is_nil(after_failure.declined_offer)

    reachable()

    assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, agent, :test)
  end

  test "an undelivered offer is settled undelivered, not ignored", ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    agent = agent(ctx.scope)

    unreachable()

    assert {:error, :harness_not_connected} =
             Work.request_turn_if_runnable(ctx.scope, agent, :test)

    assert [offer] = Offers.list_for_agent(agent.id)
    assert offer.status == :undelivered
  end
end
