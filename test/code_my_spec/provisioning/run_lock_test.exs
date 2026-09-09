defmodule CodeMySpec.Provisioning.RunLockTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.RunLock

  # A fresh, unique key per test — the registry is process-global (started
  # once by the application), so tests sharing a key would race each other
  # the same way the bug being guarded against does.
  defp project_id, do: Ecto.UUID.generate()

  describe "with_lock/2" do
    test "runs fun and returns its result when nothing else holds the lock" do
      assert RunLock.with_lock(project_id(), fn -> {:ok, :ran} end) == {:ok, :ran}
    end

    test "releases the lock once fun returns, so a later call is not blocked" do
      id = project_id()

      assert RunLock.with_lock(id, fn -> :first end) == :first
      assert RunLock.in_flight(id) == nil
      assert RunLock.with_lock(id, fn -> :second end) == :second
    end

    # The actual race this exists to close: two processes calling
    # run_devops_setup for the same project back to back, the second arriving
    # while the first is still mid-run.
    test "refuses a second concurrent run for the same project without calling fun" do
      id = project_id()
      test_pid = self()

      holder =
        spawn(fn ->
          RunLock.with_lock(id, fn ->
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked

      result =
        RunLock.with_lock(id, fn ->
          send(test_pid, :should_not_run)
          :ran
        end)

      assert {:error, {:already_running, started_at}} = result
      assert %DateTime{} = started_at
      refute_received :should_not_run

      send(holder, :release)
    end

    test "still releases the lock when fun raises" do
      id = project_id()

      assert_raise RuntimeError, "boom", fn ->
        RunLock.with_lock(id, fn -> raise "boom" end)
      end

      assert RunLock.in_flight(id) == nil
      assert RunLock.with_lock(id, fn -> :after_raise end) == :after_raise
    end

    # No `after` block runs when the holder is killed outright — this is what
    # proves the lock is not left stuck forever by a crashed run, which a
    # database-row lock would need an explicit sweeper to recover from.
    test "releases the lock when the holding process is killed" do
      id = project_id()
      test_pid = self()

      holder =
        spawn(fn ->
          RunLock.with_lock(id, fn ->
            send(test_pid, :locked)

            receive do
              :never -> :ok
            end
          end)
        end)

      assert_receive :locked
      assert RunLock.in_flight(id) != nil

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      # Registry unregisters via its own monitor asynchronously — wait for it
      # rather than asserting immediately after the kill.
      wait_until(fn -> RunLock.in_flight(id) == nil end)
    end

    test "two different projects never contend for each other's lock" do
      id_a = project_id()
      id_b = project_id()
      test_pid = self()

      holder =
        spawn(fn ->
          RunLock.with_lock(id_a, fn ->
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked

      assert RunLock.with_lock(id_b, fn -> :ok end) == :ok

      send(holder, :release)
    end
  end

  describe "in_flight/1" do
    test "nil when nothing is running for a project" do
      assert RunLock.in_flight(project_id()) == nil
    end
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    poll_result(fun.(), fun, attempts)
  end

  defp poll_result(true, _fun, _attempts), do: :ok

  defp poll_result(false, fun, attempts) do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end
end
