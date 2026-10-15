defmodule CodeMySpec.AgentPerformance.RatesChartTest do
  @moduledoc """
  Offer acceptance and tool-call failure rate, charted hourly together, and
  the teams chart's QA attempts and promotions per working copy (John,
  2026-10-14: rates over time rather than raw counts).
  """
  use CodeMySpecSpex.Case, async: true

  import Ecto.Query

  alias CodeMySpec.AgentPerformance.Chart
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.AgentPerformanceLive.Charts

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "offer acceptance counts settled offers only, claimed over claimed, ignored and declined",
       context do
    coder = Fixtures.running_agent(context.scope, role: "coding")

    for {key, status} <- [a: :claimed, b: :claimed, c: :ignored, d: :superseded, e: :open] do
      offer(coder, :work, to_string(key), status)
    end

    offer(coder, :resume, "informational", :n_a)

    assert latest(Chart.rates_option(context.scope), "offer_acceptance") == 0.6667
  end

  test "tool failure rate is failed tool results over all of them in the hour", context do
    coder = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        coder.id
      )

    for failed? <- [true, false, false, false] do
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: :tool,
        tool_call_id: "call-#{System.unique_integer([:positive])}",
        tool_failed: failed?
      })
    end

    option = Chart.rates_option(context.scope)
    assert latest(option, "tool_failure_rate") == 0.25
  end

  test "the teams chart pairs each copy's QA outcomes with its promotions, busiest first" do
    chart =
      Charts.teams(
        %{"one" => 0.5, "two" => nil},
        %{"one" => 1, "two" => 4},
        %{"one" => %{pass: 1, fail: 1}},
        []
      )

    assert chart["keys"] == ["two", "one"]
    stacks = Map.new(chart["stacks"], &{&1["name"], &1["data"]})
    assert stacks["promoted"] == [4, 1]
    assert stacks["QA pass"] == [nil, 1]
    assert stacks["QA fail"] == [nil, 1]
    assert "First-pass rate: 50%" in Enum.at(chart["details"], 1)
  end

  test "a bar chart pages ten rows at a time, every stack sliced with its categories" do
    titles = Enum.map(1..23, &"story #{&1}")

    chart = %{
      "kind" => "bars",
      "categories" => titles,
      "details" => Enum.map(titles, &[&1]),
      "stacks" => [%{"name" => "build", "data" => Enum.to_list(1..23)}]
    }

    assert Charts.page_count(chart) == 3

    last = Charts.page(chart, 3)
    assert last["categories"] == ["story 21", "story 22", "story 23"]
    assert last["details"] == [["story 21"], ["story 22"], ["story 23"]]
    assert hd(last["stacks"])["data"] == [21, 22, 23]
    assert length(Charts.page(chart, 1)["categories"]) == 10
  end

  defp offer(agent, kind, key, status) do
    %Offer{id: id} = Offers.record(nil, agent, kind, {"requirement", key})
    Repo.update_all(from(o in Offer, where: o.id == ^id), set: [status: status])
  end

  defp latest(option, name) do
    option["series"]
    |> Enum.find(&(&1["name"] == name))
    |> Map.fetch!("data")
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end
end
