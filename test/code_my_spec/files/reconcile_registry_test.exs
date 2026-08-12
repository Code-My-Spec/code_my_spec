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

  test "a harness with nothing in flight reports nothing" do
    assert ReconcileRegistry.in_flight(Ecto.UUID.generate()) == nil
  end

  test "nil harness is not an error — plenty of scopes name no working copy" do
    assert ReconcileRegistry.mark(nil, 10) == :ok
    assert ReconcileRegistry.in_flight(nil) == nil
  end

  test "a marked harness reports what is landing" do
    harness_id = Ecto.UUID.generate()
    test_pid = self()

    task =
      Task.async(fn ->
        ReconcileRegistry.mark(harness_id, 3937)
        send(test_pid, :marked)
        # Hold the registration open — it lives as long as this process.
        receive do: (:release -> :ok)
      end)

    assert_receive :marked

    assert %{count: 3937, started_at: %DateTime{}} = ReconcileRegistry.in_flight(harness_id)

    send(task.pid, :release)
    Task.await(task)
  end

  # The property that makes this safe to add: nothing cleans up, because there
  # is nothing to clean up. A crashed reconcile takes its marker with it, and a
  # server that restarts mid-reconcile comes back with an empty table — which is
  # true, since nothing is reconciling any more.
  test "the marker dies with the task, including when it crashes" do
    harness_id = Ecto.UUID.generate()
    test_pid = self()

    {:ok, pid} =
      Task.start(fn ->
        ReconcileRegistry.mark(harness_id, 12)
        send(test_pid, :marked)
        receive do: (:boom -> exit(:crashed))
      end)

    assert_receive :marked
    assert ReconcileRegistry.in_flight(harness_id)

    ref = Process.monitor(pid)
    send(pid, :boom)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    # Registry unregisters on process exit; give it the scheduler turn to do so.
    Process.sleep(20)

    refute ReconcileRegistry.in_flight(harness_id),
           "a crashed reconcile must not leave a marker claiming one is running"
  end
end
