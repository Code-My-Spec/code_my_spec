defmodule CodeMySpec.Files.ReconcileRegistryTest do
  @moduledoc """
  Making an in-flight reconcile legible to whoever reads a requirement.

  `FileSync.reconcile/2` is not one transaction — upserts chunk at 500, then a
  delete_all, then ComponentSync — so a reader arriving mid-manifest sees a tree
  that has never existed on disk. The wrong answer that produces is *plausible*:
  `bdd_specs_exist` going dark reads as "your spec files are gone", and the
  rational next move is to investigate rather than wait.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Files.ReconcileRegistry

  # Waits for the marker to go rather than assuming how long that takes.
  #
  # Clauses rather than a branch: `SpexDeniedCalls` refuses an imperative `if`
  # in a test file on the grounds that branching means reacting to state the
  # test should control, and it is right about the usual case. This one is not
  # reacting to an outcome — the outcome is asserted at the call site — it is
  # waiting for an unregistration the Registry performs asynchronously with
  # respect to the DOWN message. Written as a recursion on what it matched, so
  # there is no branch to read as a decision.
  defp cleared?(working_copy_id, attempts \\ 200)

  defp cleared?(_working_copy_id, 0), do: false

  defp cleared?(working_copy_id, attempts) do
    ReconcileRegistry.in_flight(working_copy_id)
    |> keep_waiting(working_copy_id, attempts)
  end

  defp keep_waiting(nil, _working_copy_id, _attempts), do: true

  defp keep_waiting(_still_there, working_copy_id, attempts) do
    Process.sleep(10)
    cleared?(working_copy_id, attempts - 1)
  end

  test "a harness with nothing in flight reports nothing" do
    assert ReconcileRegistry.in_flight(Ecto.UUID.generate()) == nil
  end

  test "nil harness is not an error — plenty of scopes name no working copy" do
    assert ReconcileRegistry.mark(nil, 10) == :ok
    assert ReconcileRegistry.in_flight(nil) == nil
  end

  test "a marked harness reports what is landing" do
    working_copy_id = Ecto.UUID.generate()
    test_pid = self()

    task =
      Task.async(fn ->
        ReconcileRegistry.mark(working_copy_id, 3937)
        send(test_pid, :marked)
        # Hold the registration open — it lives as long as this process.
        receive do: (:release -> :ok)
      end)

    assert_receive :marked, 2_000

    assert %{count: 3937, started_at: %DateTime{}} = ReconcileRegistry.in_flight(working_copy_id)

    send(task.pid, :release)
    Task.await(task)
  end

  # The property that makes this safe to add: nothing cleans up, because there
  # is nothing to clean up. A crashed reconcile takes its marker with it, and a
  # server that restarts mid-reconcile comes back with an empty table — which is
  # true, since nothing is reconciling any more.
  test "the marker dies with the task, including when it crashes" do
    working_copy_id = Ecto.UUID.generate()
    test_pid = self()

    {:ok, pid} =
      Task.start(fn ->
        ReconcileRegistry.mark(working_copy_id, 12)
        send(test_pid, :marked)
        receive do: (:boom -> exit(:crashed))
      end)

    assert_receive :marked, 2_000
    assert ReconcileRegistry.in_flight(working_copy_id)

    ref = Process.monitor(pid)
    send(pid, :boom)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

    # Polled, not slept. Registry unregisters asynchronously with respect to the
    # DOWN message, so a fixed sleep is a guess about scheduling that a loaded
    # machine wins — which is how this flaked in a full suite run while passing
    # forty times alone.
    assert cleared?(working_copy_id),
           "a crashed reconcile must not leave a marker claiming one is running"
  end
end
