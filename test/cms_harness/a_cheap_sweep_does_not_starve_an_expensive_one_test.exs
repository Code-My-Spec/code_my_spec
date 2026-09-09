defmodule CmsHarness.ACheapSweepDoesNotStarveAnExpensiveOneTest do
  @moduledoc """
  A cheap analyzer arriving later does not go in front of one already waiting.

  `insert_by_cost/2` sorted the whole queue on every arrival. That is right for
  a single batch — the two sources an agent can act on immediately should come
  first — and wrong the moment requests keep coming, because the cheap one keeps
  arriving and the expensive one never reaches the front.

  Measured on Broken Oaths 2026-09-08, after in-flight runs were allowed to
  finish: six compiler sweeps completed in thirty seconds and not one spex
  sweep, on a copy whose coding agent was blocked waiting for exactly that spex
  result. `bdd_specs_passing` needs a fresh spex run to latch, so no amount of
  correct work could satisfy the requirement.

  Cost ordering still applies within a batch. What changed is that a batch
  cannot preempt what was already queued.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  defp state(queue) do
    %{project: %{root: "/tmp/a-checkout"}, running: %{source: "credo", run_id: 1}, queue: queue, timer: nil}
  end

  defp enqueue(state, sources) do
    runs =
      sources
      |> Enum.with_index(2)
      |> Enum.map(fn {source, i} -> %{"run_id" => i, "source" => source, "args" => []} end)

    {:noreply, next} = AnalysisServer.handle_cast({:enqueue, runs}, state)
    next
  end

  defp sources(state), do: Enum.map(state.queue, & &1.source)

  test "a batch is still ordered cheapest first" do
    after_state = state([]) |> enqueue(["spex", "compiler"])

    assert sources(after_state) == ["compiler", "spex"],
           "within one arrival the fast answer an agent can act on still comes first"
  end

  test "a later cheap arrival waits behind an already-queued expensive one" do
    after_state =
      state([])
      |> enqueue(["spex"])
      |> enqueue(["compiler"])

    assert sources(after_state) == ["spex", "compiler"],
           "the compiler request jumped a queued spex, and with one arriving " <>
             "every few seconds the spex sweep never started"
  end

  test "repeated cheap arrivals never overtake the waiting sweep" do
    after_state =
      Enum.reduce(1..5, enqueue(state([]), ["spex"]), fn _i, acc ->
        enqueue(acc, ["compiler"])
      end)

    assert hd(sources(after_state)) == "spex",
           "five arrivals later the expensive sweep is still first in line"
  end
end
