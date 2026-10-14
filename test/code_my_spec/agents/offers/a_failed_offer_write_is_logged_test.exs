defmodule CodeMySpec.Agents.Offers.AFailedOfferWriteIsLoggedTest do
  @moduledoc """
  f5699eb9: an offer that could not be written answered nil and said nothing,
  so an empty offers table could not be told from one nobody wrote to.
  """
  use CodeMySpecSpex.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations.Message
  alias CodeMySpecTest.AgentPresence

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "an offer for an agent with no row logs a warning and answers nil", ctx do
    ghost = %Agent{
      id: Ecto.UUID.generate(),
      account_id: ctx.scope.active_account_id,
      project_id: ctx.scope.active_project_id
    }

    log =
      capture_log([level: :warning], fn ->
        assert Offers.record(nil, ghost, :resume, {"restart", nil}) == nil
      end)

    assert log =~ "[Offers] offer not recorded"
    assert log =~ "kind=:resume"
    assert log =~ ~s(subject={"restart", nil})
    assert log =~ "agent=#{ghost.id}"
    assert log =~ "agent_id"
  end

  test "a link to a message with no row logs a warning and still answers the offer", ctx do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        working_copy: "/tmp/offers-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    missing = Ecto.UUID.generate()

    log =
      capture_log([level: :warning], fn ->
        assert %{kind: :resume} =
                 Offers.record({:ok, %Message{id: missing}}, agent, :resume, {"restart", nil})
      end)

    assert log =~ "not linked to message #{missing}"
    assert log =~ "message_id"
  end
end
