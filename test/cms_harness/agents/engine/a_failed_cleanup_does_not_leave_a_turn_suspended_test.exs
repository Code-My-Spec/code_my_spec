defmodule CmsHarness.Agents.Engine.AFailedCleanupDoesNotLeaveATurnSuspendedTest do
  @moduledoc """
  `Execution.stop_owned/2` keeps the owners suspended when it cannot confirm
  their OS groups are gone, which analysis needs: they hold its capacity. An
  agent's turn holds none, and a turn stopped that way stayed suspended for
  good. `stop_and_release/2` releases them and still reports the failure.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Execution

  test "an unconfirmed cleanup still ends the turn's processes, and says so" do
    test_pid = self()

    root =
      spawn(fn ->
        child = spawn(fn -> Process.sleep(:infinity) end)
        Process.put(:"$ancestors", [])
        send(test_pid, {:child, child})
        Process.sleep(:infinity)
      end)

    assert_receive {:child, _child}
    # A deadline already passed: confirmation cannot succeed.
    past = System.monotonic_time(:millisecond) - 1

    assert {:error,
            {:cleanup_incomplete, {:error, {:subprocess_shutdown_unconfirmed, _, _}}, _, _}} =
             Execution.stop_and_release(root, past)

    refute Process.alive?(root), "the turn's process was left suspended"
  end

  test "cleanup of an exited owner still releases its surviving descendant" do
    parent = self()

    root =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    monitor = Process.monitor(root)

    child =
      spawn(fn ->
        Process.put(:"$ancestors", [root])
        send(parent, :descendant_ready)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(child, :kill) end)
    assert_receive :descendant_ready
    send(root, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}

    assert :ok = Execution.stop_and_release(root)
    refute Process.alive?(child)
  end

  test "a confirmed cleanup answers :ok and ends the turn's processes" do
    root = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok = Execution.stop_and_release(root)
    refute Process.alive?(root)
  end
end
