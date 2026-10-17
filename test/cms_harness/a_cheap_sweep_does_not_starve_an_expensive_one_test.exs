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
    %{
      project: %{root: "/tmp/a-checkout"},
      running: %{source: "credo", run_id: 1},
      queue: queue,
      timer: nil,
      pending_cleanups: []
    }
  end

  # `System.unique_integer/1` rather than `Enum.with_index/2`: the latter
  # restarts at its offset on every call, so two separate `enqueue/2` calls —
  # exactly what "a later arrival" means here — minted the same `run_id`.
  # `state.running`'s `run_id: 1` is fixed and never reused by an arrival, so
  # `holds_run?/2` read the second batch's request as a resend of the first
  # batch's already-queued one and dropped it silently: the queue this was
  # supposed to test never grew past one entry, `f2ff4147`.
  defp enqueue(state, sources) do
    runs =
      sources
      |> Enum.map(fn source ->
        %{"run_id" => System.unique_integer([:positive]), "source" => source, "args" => []}
      end)

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
