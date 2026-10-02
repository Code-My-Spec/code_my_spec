defmodule CodeMySpec.Embeddings.OrtexServingTest do
  @moduledoc """
  The priority queue, not the model: every test here injects `:run_fn` so
  none of this touches Ortex, the ONNX file, or the tokenizer — OrtexServing
  is a GenServer with a dispatch policy, and that policy is what's under
  test.

  `async: false`: `start_link/1` always registers as `OrtexServing` itself
  (the production name every caller dispatches to), so only one instance
  can exist in the test suite at a time.
  """

  use ExUnit.Case, async: false

  alias CodeMySpec.Embeddings.OrtexServing

  # A run_fn the test controls completely. Every run reports, in order, to
  # the test process — that reported order is what's under test, not
  # wall-clock timing, so assertions don't race against how fast an
  # already-dispatched job happens to finish. The "block" job waits on the
  # test process's go-ahead before reporting and returning, which is what
  # holds a job "in flight" long enough for the rest to queue up behind it.
  defp reporting_run_fn(test_pid) do
    fn _pipeline, job ->
      {tag, result} = job_outcome(job)
      wait_for_go_if_blocked(tag, test_pid)
      send(test_pid, {:ran, tag})
      result
    end
  end

  defp job_outcome({:batch, ["block"]}), do: {:blocked, {:ok, [[0.0]]}}
  defp job_outcome({:batch, [text]}), do: {String.to_atom(text), {:ok, [[text]]}}
  defp job_outcome({:single, text}), do: {String.to_atom(text), {:ok, [text]}}

  defp wait_for_go_if_blocked(:blocked, test_pid) do
    send(test_pid, {:worker_blocked, self()})

    receive do
      :go -> :ok
    end
  end

  defp wait_for_go_if_blocked(_tag, _test_pid), do: :ok

  test "a search submitted after queued bulk jobs is served before them" do
    test_pid = self()
    _pid = start_supervised!({OrtexServing, run_fn: reporting_run_fn(test_pid)})

    # Dispatched straight to the worker (nothing queued yet) and held there
    # — this is the one in-flight batch a search can't avoid waiting
    # behind, the worst case the design accepts.
    blocking_task = Task.async(fn -> OrtexServing.embed_batch(["block"], :bulk) end)
    assert_receive {:worker_blocked, worker_pid}, 1_000

    # Both land in the queues, never in the worker, while "block" holds it
    # — enqueued bulk-then-search is the exact ordering the priority has to
    # override. Each task reports immediately before making its (blocking)
    # call, in the same process and strictly before the send a GenServer
    # call makes — so waiting for that report here guarantees the bulk
    # message reached the mailbox before the search task is even spawned,
    # rather than racing two independently-scheduled processes against
    # each other.
    bulk_task =
      Task.async(fn ->
        send(test_pid, :bulk_calling)
        OrtexServing.embed_batch(["second"], :bulk)
      end)

    assert_receive :bulk_calling, 1_000

    search_task =
      Task.async(fn ->
        send(test_pid, :search_calling)
        OrtexServing.embed("third", :search)
      end)

    assert_receive :search_calling, 1_000
    # A small margin for the GenServer to have actually processed both
    # enqueue calls — the markers above guarantee *send order*, not that
    # the server has dequeued them yet.
    Process.sleep(20)

    send(worker_pid, :go)

    assert {:ok, [[+0.0]]} = Task.await(blocking_task)
    assert {:ok, "third"} = Task.await(search_task)
    assert {:ok, [["second"]]} = Task.await(bulk_task)

    assert_received {:ran, :blocked}
    assert_received {:ran, :third}
    assert_received {:ran, :second}
  end

  test "bulk jobs with nothing queued ahead still complete" do
    _pid = start_supervised!({OrtexServing, run_fn: reporting_run_fn(self())})

    assert {:ok, [["x"]]} = OrtexServing.embed_batch(["x"], :bulk)
  end

  test "search with nothing queued ahead still completes" do
    _pid = start_supervised!({OrtexServing, run_fn: reporting_run_fn(self())})

    assert {:ok, "q"} = OrtexServing.embed("q", :search)
  end
end
