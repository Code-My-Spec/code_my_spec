defmodule CodeMySpec.McpServers.Requirements.APullIsBackedByTheSameOfferAPushWouldMakeTest do
  @moduledoc """
  Issue e6f18e57: `get_next_requirement` showed an agent actionable work
  with no offer behind it, so `reject_offer` (per main's instruction) had
  nothing to decline. Per product: work a pull shows is backed by the same
  single open offer a pushed turn would carry (criteria 2158, 2161, 2163).
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

  test "names the offer and reject_offer, reuses it on a repeat pull, and does not re-offer it once declined",
       ctx do
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.agent.id}}

    assert {:reply, first, _} = GetNextRequirement.execute(%{}, frame)
    content = response_text(first)
    assert content =~ "requirement_name=`"

    assert [offer] = Offers.list_for_agent(ctx.agent.id)
    assert offer.status == :open
    assert offer.kind == :work
    assert content =~ offer.id
    assert content =~ "reject_offer"

    # A repeat pull before anything changes finds the same offer open --
    # not a second attempt, not a climb of its ladder.
    assert {:reply, repeat, _} = GetNextRequirement.execute(%{}, frame)
    assert response_text(repeat) =~ offer.id
    assert [^offer] = Offers.list_for_agent(ctx.agent.id)

    assert {:ok, decline_text} =
             RejectOffer.call(
               %{reason: "not this agent's scope"},
               %{agent_id: ctx.agent.id, scope: ctx.scope}
             )

    assert decline_text =~ offer.id
    declined_key = offer.subject_key

    assert {:reply, after_decline, _} = GetNextRequirement.execute(%{}, frame)
    refute response_text(after_decline) =~ offer.id

    refute Enum.any?(
             Offers.list_for_agent(ctx.agent.id),
             &(&1.status == :open and &1.subject_key == declined_key)
           ),
           "the declined work was offered again before main acted on it"
  end
end
