defmodule CodeMySpec.McpServers.Requirements.APullIsBackedByTheSameOfferAPushWouldMakeTest do
  @moduledoc """
  Issue e6f18e57: `get_next_requirement` showed an agent actionable work
  with no offer behind it, so `reject_offer` (per main's instruction) had
  nothing to decline. Product's ruling (7371fb26): a pull stays a pure read
  -- it never records an offer or climbs a ladder -- and `reject_offer`
  called with no open offer and no id declines whatever work the pull most
  recently showed instead, writing that decline directly.
  """
  use CodeMySpecSpex.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Tools.RejectOffer
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        status: :running,
        working_copy: "/tmp/pull-offer-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    Map.put(ctx, :agent, agent)
  end

  test "a pull records nothing, and reject_offer with no id declines what it showed", ctx do
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.agent.id}}

    assert {:reply, first, _} = GetNextRequirement.execute(%{}, frame)
    content = response_text(first)
    assert [_, shown_name] = Regex.run(~r/requirement_name=`(\w+)`/, content)

    # A pull is a pure read: nothing is recorded just by asking.
    assert Offers.list_for_agent(ctx.agent.id) == []

    # Repeating the pull still records nothing.
    assert {:reply, repeat, _} = GetNextRequirement.execute(%{}, frame)
    assert response_text(repeat) == content
    assert Offers.list_for_agent(ctx.agent.id) == []

    assert {:ok, decline_text} =
             RejectOffer.call(
               %{reason: "not this agent's scope"},
               %{agent_id: ctx.agent.id, scope: ctx.scope}
             )

    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :declined
    assert offer.kind == :work
    assert offer.reason == "not this agent's scope"
    assert decline_text =~ offer.id
    declined_key = offer.subject_key

    assert {:reply, after_decline, _} = GetNextRequirement.execute(%{}, frame)
    refute response_text(after_decline) =~ "requirement_name=`#{shown_name}`"

    refute Enum.any?(
             Offers.list_for_agent(ctx.agent.id),
             &(&1.status == :open and &1.subject_key == declined_key)
           ),
           "the declined work was offered again before main acted on it"
  end

  test "reject_offer with no open offer and nothing shown refuses rather than inventing one", ctx do
    assert {:error, :not_found} =
             CodeMySpec.Agents.Offers.reject(ctx.agent.id, nil, "nothing to decline")
  end
end
