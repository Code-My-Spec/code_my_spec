defmodule CodeMySpec.Agents.Offers.ListingOffersTest do
  @moduledoc "`Offers.list/2` and `count_by_kind_and_status/2`: filters, scope, and the count table."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Tools.OfferResponses, as: OfferMapper

  setup do
    scope = full_scope_fixture()
    %{scope: scope, coding: agent(scope, "coding"), qa: agent(scope, "qa")}
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        working_copy: "/tmp/listing-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  defp offer(agent, kind, key), do: %Offer{} = Offers.record(nil, agent, kind, {"t", key})

  defp ids(offers), do: Enum.map(offers, & &1.id)

  test "newest first, with the agent and links preloaded", ctx do
    first = offer(ctx.coding, :work, "a")
    second = offer(ctx.qa, :problems, "b")

    assert [listed_second, listed_first] = Offers.list(ctx.scope)
    assert {listed_second.id, listed_first.id} == {second.id, first.id}
    assert listed_second.agent.role == :qa
    assert listed_first.messages == []
  end

  test "agent_id, kind, status and since each narrow it", ctx do
    work = offer(ctx.coding, :work, "a")
    problems = offer(ctx.coding, :problems, "b")
    qa_work = offer(ctx.qa, :work, "c")
    Offers.undelivered(problems)

    assert ids(Offers.list(ctx.scope, agent_id: ctx.qa.id)) == [qa_work.id]
    assert ids(Offers.list(ctx.scope, kind: :work)) == [qa_work.id, work.id]
    assert ids(Offers.list(ctx.scope, status: :undelivered)) == [problems.id]
    assert Offers.list(ctx.scope, since: DateTime.add(DateTime.utc_now(), 60, :second)) == []
    assert length(Offers.list(ctx.scope, since: work.inserted_at)) == 3
  end

  test "limit caps the list but not the counts", ctx do
    for key <- ~w(a b c), do: offer(ctx.coding, :work, key)

    assert length(Offers.list(ctx.scope, limit: 2)) == 2
    assert Offers.count_by_kind_and_status(ctx.scope, limit: 2) == %{{:work, :open} => 3}
  end

  test "another project's offers are not this project's", ctx do
    offer(ctx.coding, :work, "a")
    other = full_scope_fixture()
    offer(agent(other, "coding"), :work, "z")

    assert [%{agent_id: id}] = Offers.list(ctx.scope)
    assert id == ctx.coding.id
    assert Offers.count_by_kind_and_status(ctx.scope) == %{{:work, :open} => 1}
  end

  test "counts by kind and status, and the table prints only what occurs", ctx do
    offer(ctx.coding, :work, "a")
    offer(ctx.coding, :work, "a")
    offer(ctx.qa, :work, "b")
    ctx.qa |> offer(:problems, "c") |> Offers.undelivered()

    counts = Offers.count_by_kind_and_status(ctx.scope)

    assert counts == %{
             {:work, :open} => 2,
             {:work, :superseded} => 1,
             {:problems, :undelivered} => 1
           }

    assert OfferMapper.table(counts) ==
             """
             kind      open  superseded  undelivered  total
             work         2           1            0      3
             problems     0           0            1      1\
             """
  end

  test "an empty match says so", ctx do
    assert OfferMapper.text([], Offers.count_by_kind_and_status(ctx.scope)) == "No offers match."
  end
end
