defmodule CmsHarnessTest.SlotHolder do
  @moduledoc """
  Occupying a machine-wide analyzer slot directly, for scenarios about what a
  harness does when it cannot get one.

  The same technique `analysis_slots_test.exs` already uses — a spawned
  process that takes a slot and goes on existing, rather than a second real
  harness (`CmsHarnessTest.FakeServer` is a singleton per test process and
  cannot address two connected harnesses independently). Extracted here
  because a spex file may not call `send/2` directly (its own `.credo.exs`
  rule: "trigger behavior through the UI or public API instead"), and
  `release/1` is that public API — the send lives in the one place that owns
  the holder process, not in the scenario driving it.
  """

  import ExUnit.Assertions

  alias CmsHarness.AnalysisSlots

  @doc """
  Take a slot and hold it until `release/1` is called. Returns the pid.

  Registers its own `on_exit` cleanup, so a failing assertion cannot leave
  a slot held into the next test.
  """
  @spec occupy() :: pid()
  def occupy do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:took, AnalysisSlots.acquire()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:took, :ok}, 1_000
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)

    pid
  end

  @doc "Free a slot taken by `occupy/0`."
  @spec release(pid()) :: :ok
  def release(pid) do
    send(pid, :release)
    :ok
  end
end
