defmodule CodeMySpec.Agents.Main.ATurnOnItsWayIsNotAStallTest do
  @moduledoc """
  A turn handed to an agent's harness and not yet started is not a stall; one
  that never started is, and says what was offered.

  Main was told "STALLED: unclaimed work" for team 2's coder at 03:21:36, with
  the promote it claimed at 03:21:46 offered at 03:21:35 (2026-10-13). A flag
  that fires on every handover is one main learns to discount.
  """
  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        continuous: true,
        status: :running,
        working_copy: "/tmp/turn-on-its-way",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(coder)
    %{scope: scope, coder: coder}
  end

  defp aged(offer, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Repo.update_all(from(o in Offer, where: o.id == ^offer.id), set: [turn_requested_at: at])
  end

  test "a turn just handed over is on its way, not unstarted", %{coder: coder} do
    {:ok, _} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})

    assert Offers.in_flight?(coder.id)
    assert is_nil(Offers.unstarted_turn(coder.id))
  end

  test "a turn past its window never started, and names what was offered", %{coder: coder} do
    {:ok, offer} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})
    aged(offer, 301)

    refute Offers.in_flight?(coder.id)
    assert %{id: id, subject_key: "story:1:story_promoted"} = Offers.unstarted_turn(coder.id)
    assert id == offer.id
  end

  test "offering again supersedes the lapsed request, and it still reads unstarted",
       %{coder: coder} do
    {:ok, first} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})
    aged(first, 301)
    {:ok, _second} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})

    assert %{status: :superseded, note: "never started"} = Repo.get!(Offer, first.id)
    assert Offers.in_flight?(coder.id)
    assert %{id: id} = Offers.unstarted_turn(coder.id)
    assert id == first.id
  end

  test "a turn the agent took since ends the stall", %{coder: coder} do
    {:ok, first} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})
    aged(first, 301)
    {:ok, second} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})

    now = DateTime.utc_now()

    Repo.update_all(from(o in Offer, where: o.id == ^second.id),
      set: [status: :claimed, outcome_at: now]
    )

    assert is_nil(Offers.unstarted_turn(coder.id))
  end

  # The digest's view, which is what main is told: a coder with work waiting
  # and no turn running.
  defp coder_entry(attrs) do
    struct(
      AgentWork,
      Map.merge(
        %{
          agent_id: "coder",
          role: :coding,
          agent_status: :running,
          continuous?: true,
          idle?: false
        },
        attrs
      )
    )
  end

  defp stalled?(attrs), do: Digest.stalled(%Digest{work: [coder_entry(attrs)]}) != []

  test "work waiting and a turn on its way is not a stall" do
    refute stalled?(%{turn_in_flight?: true})
  end

  test "work waiting and nothing on its way is" do
    assert stalled?(%{turn_in_flight?: false})
  end

  test "a turn on its way after one that never started is", %{coder: coder} do
    {:ok, offer} = Offers.dispatch(coder, :work, {"requirement", "story:1:story_promoted"})
    assert stalled?(%{turn_in_flight?: true, unstarted_turn: offer})
  end
end
