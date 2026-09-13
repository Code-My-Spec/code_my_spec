defmodule CmsHarness.ARunningSweepAnswersForTheNextRequestTest do
  @moduledoc """
  A request arriving while its source is mid-sweep is tied to the next run.

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

  That first fix (superseding a running-source duplicate with an empty
  answer) traded starvation for silence: the duplicate got *no* real result,
  ever. Superseded to a fresh queue entry, tied — every request for a source
  already running or queued now shares one upcoming execution and all of them
  get its real result, story 839 criterion 3439: tied to the *next* run, not
  the one in flight, because the in-flight run may be answering input that is
  now stale relative to what prompted the new request.

  Driven through `handle_cast({:enqueue, _})`, which is the path the channel
  uses. Every case here leaves a sweep running, so `maybe_start_next/1` has
  nothing to start and no analyzer is shelled out.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  defp state(running_source, queued_sources) do
    %{
      project: %{root: "/tmp/a-checkout"},
      running: %{source: running_source, run_id: 1, tied_run_ids: [], task: nil},
      queue: Enum.map(queued_sources, &%{run_id: 99, tied_run_ids: [], source: &1, args: []}),
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

  test "a second request for a running source schedules the next run rather than dying silently" do
    after_state = state("spex", []) |> enqueue("spex")

    assert [%{source: "spex", run_id: 2, tied_run_ids: []}] = after_state.queue,
           "a duplicate for a running source needs something to tie onto once " <>
             "it starts, and this is the first one — it becomes the next run"
  end

  test "a request for a different source still queues, untied" do
    after_state = state("spex", []) |> enqueue("credo")

    assert [%{source: "credo", tied_run_ids: []}] = after_state.queue
  end

  # A duplicate for an already-*queued* source never grows the queue — it ties
  # onto the entry already waiting, so one execution answers for all of them.
  test "the queued case ties on rather than queueing a second entry" do
    after_state = state("credo", ["spex"]) |> enqueue("spex")

    assert [%{source: "spex", run_id: 99, tied_run_ids: [2]}] = after_state.queue
  end

  test "a third request for the same running source ties onto the second, not a third entry" do
    after_state = state("spex", []) |> enqueue("spex") |> enqueue_run_id(3, "spex")

    assert [%{source: "spex", run_id: 2, tied_run_ids: [3]}] = after_state.queue
  end

  defp enqueue_run_id(state, run_id, source) do
    {:noreply, next} =
      AnalysisServer.handle_cast(
        {:enqueue, [%{"run_id" => run_id, "source" => source, "args" => []}]},
        state
      )

    next
  end
end
