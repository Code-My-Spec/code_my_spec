defmodule CodeMySpec.Requirements.APullIsBackedByTheSameOfferAPushWouldMakeTest do
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
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.ToolLibrary
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

    assert first = ToolLibrary.run("get_next_requirement", %{}, tool_context(frame))
    content = response_text(first)
    assert [_, shown_name] = Regex.run(~r/requirement_name=`(\w+)`/, content)

    # A pull is a pure read: nothing is recorded just by asking.
    assert Offers.list_for_agent(ctx.agent.id) == []

    # Repeating the pull still records nothing.
    assert repeat = ToolLibrary.run("get_next_requirement", %{}, tool_context(frame))
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

    assert after_decline = ToolLibrary.run("get_next_requirement", %{}, tool_context(frame))
    # Product correction on 006b2b56: a decline damps pushes only.
    assert response_text(after_decline) =~ "requirement_name=`#{shown_name}`"
    assert response_text(after_decline) =~ "you declined this at"
    assert response_text(after_decline) =~ "not this agent's scope"

    refute Enum.any?(
             Offers.list_for_agent(ctx.agent.id),
             &(&1.status == :open and &1.subject_key == declined_key)
           ),
           "the declined work was offered again before main acted on it"
  end

  # An offer recorded before the team moved story, or before its requirement
  # stopped being actionable, named work start_task then refused.
  test "a pull names an open offer only for work it shows", ctx do
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.agent.id}}

    {:ok, stale} = Offers.dispatch(ctx.agent, :work, {"requirement", "story:99999:qa_complete"})
    stale_shown = ToolLibrary.run("get_next_requirement", %{}, tool_context(frame))

    refute response_text(stale_shown) =~ stale.id,
           "the pull named an offer for work it does not show"

    {kind, subject} = Work.shown_work(ctx.scope, ctx.agent)
    {:ok, current} = Offers.dispatch(ctx.agent, kind, subject)
    current_shown = ToolLibrary.run("get_next_requirement", %{}, tool_context(frame))

    assert response_text(current_shown) =~ "backed by offer `#{current.id}`"
  end

  test "reject_offer with no open offer and nothing shown refuses rather than inventing one",
       ctx do
    assert {:error, :not_found} =
             Offers.reject(ctx.agent.id, nil, "nothing to decline")
  end

  # A tool runs from a frame's assigns, with the scope under the key ToolLibrary reads.
  defp tool_context(%{assigns: assigns}), do: Map.put(assigns, :scope, assigns[:current_scope])
end
