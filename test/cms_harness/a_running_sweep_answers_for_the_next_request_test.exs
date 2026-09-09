defmodule CmsHarness.ARunningSweepAnswersForTheNextRequestTest do
  @moduledoc """
  A request arriving while its source is mid-sweep is answered by that sweep.

  `accept/2` already refused a second *queued* run for one source, on the
  argument that it "would only deliver the same answer twice". A run that has
  been dequeued and is executing is not in the queue, so the guard never saw it:
  a request arriving while spex was mid-sweep was accepted and stacked behind
  it, and with a continuous agent stopping every ten seconds the next one
  stacked behind that.

  Measured on Broken Oaths 2026-09-08: 397 superseded runs against 25 completed
  in ninety minutes, and no spex sweep finishing for thirty-four minutes on a
  suite that takes under three. `bdd_specs_passing` needs a fresh spex run to
  latch, so the agent holding that requirement waited on a sweep that could not
  land — "purely waiting on the background spex sweep", in its own words — and
  stopped, which queued another one.

  John: "We can't be superseding runs like that. We have to let it finish."

  Driven through `handle_cast({:enqueue, _})`, which is the path the channel
  uses. Every case here leaves a sweep running, so `maybe_start_next/1` has
  nothing to start and no analyzer is shelled out.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  defp state(running_source, queued_sources) do
    %{
      project: %{root: "/tmp/a-checkout"},
      running: %{source: running_source, run_id: 1, task: nil},
      queue: Enum.map(queued_sources, &%{run_id: 99, source: &1, args: []}),
      timer: nil
    }
  end

  defp enqueue(state, source) do
    {:noreply, next} =
      AnalysisServer.handle_cast(
        {:enqueue, [%{"run_id" => 2, "source" => source, "args" => []}]},
        state
      )

    next
  end

  test "a second request for a running source does not queue behind it" do
    after_state = state("spex", []) |> enqueue("spex")

    assert after_state.queue == [],
           "the sweep already running answers for this request; queueing another " <>
             "is how a continuous agent starved spex of a completion"
  end

  test "a request for a different source still queues" do
    after_state = state("spex", []) |> enqueue("credo")

    assert [%{source: "credo"}] = after_state.queue
  end

  # Unchanged: a second request for an already-queued source was always refused.
  test "the queued case still refuses" do
    after_state = state("credo", ["spex"]) |> enqueue("spex")

    assert length(after_state.queue) == 1
  end
end
