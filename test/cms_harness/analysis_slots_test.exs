defmodule CmsHarness.AnalysisSlotsTest do
  @moduledoc """
  How many analyzer suites this machine runs at once, across every working copy.

  `Project.AnalysisServer` serializes within one copy because `mix test` and
  `mix spex` share `_build/test`. Nothing serialized across copies, and one
  harness serves every checkout on the machine — so six agents each wanting a
  fresh sweep before promoting started six full suites against one box.

  Measured 2026-09-12 (`3e9b7568`): load 54 on ten cores with eight concurrent
  suites, and again at 17–21 with three. Under that load the analyzer
  manufactures failures — whichever test is heaviest dies with
  `** (EXIT from #PID<…>)`, passes in isolation, and the victim moves between
  sweeps. Three promotions were refused in one session naming three different
  innocent tests, each green twenty consecutive runs later.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.AnalysisSlots

  # The harness supervisor already runs it, so this uses that instance rather
  # than starting a second under the same name. Waits for a clean slate instead:
  # the previous test's holders are killed by its `on_exit`, and the DOWN that
  # frees each slot arrives a moment later.
  setup do
    assert is_pid(Process.whereis(AnalysisSlots)),
           "the harness supervisor is expected to run this"

    wait_until(fn -> AnalysisSlots.in_use() == 0 end)
    :ok
  end

  # Held for the caller's lifetime, so a slot is taken by a process that goes on
  # existing rather than by one that returns immediately.
  #
  # Registers its own cleanup, so a failing assertion cannot leave a slot held
  # into the next test — which would fail that one for the previous one's
  # reason.
  defp holder do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:took, AnalysisSlots.acquire()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)

    receive do
      {:took, answer} -> {pid, answer}
    after
      1000 -> flunk("the holder never answered")
    end
  end

  describe "the limit" do
    test "is a fraction of the cores, not a count of projects" do
      assert AnalysisSlots.limit() == max(1, div(System.schedulers_online(), 4))

      assert AnalysisSlots.limit() >= 1,
             "a limit of zero would stop analysis on the whole machine"
    end

    test "is configurable for a box that is only doing one thing" do
      Application.put_env(:code_my_spec, :analysis_slots, 7)
      on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)

      assert AnalysisSlots.limit() == 7
    end
  end

  describe "acquiring" do
    setup do
      Application.put_env(:code_my_spec, :analysis_slots, 2)
      on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)
    end

    test "grants up to the limit" do
      assert {_pid, :ok} = holder()
      assert {_pid, :ok} = holder()
      assert AnalysisSlots.in_use() == 2
    end

    # Not queued. `AnalysisServer` arms its thirty-minute kill timer at dispatch,
    # before the run reaches the slot, so a run that waited its turn would spend
    # that budget waiting and then be killed for being slow — reported as a hung
    # tool, which is the misattribution this whole thing exists to prevent.
    test "refuses the one past the limit rather than making it wait" do
      {_first, :ok} = holder()
      {_second, :ok} = holder()

      assert {_third, :busy} = holder(),
             "a third run was admitted, or worse, left waiting behind the other two"
    end

    test "a refused caller holds nothing" do
      {_first, :ok} = holder()
      {_second, :ok} = holder()
      {_third, :busy} = holder()

      assert AnalysisSlots.in_use() == 2
    end
  end

  describe "releasing" do
    setup do
      Application.put_env(:code_my_spec, :analysis_slots, 1)
      on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)
    end

    # By death rather than by discipline: there is no release to forget and none
    # to call twice. A semaphore that leaks stops analysis on the whole machine,
    # which is worse than the saturation it was added to fix.
    test "a slot comes back when its holder exits normally" do
      {pid, :ok} = holder()
      assert AnalysisSlots.in_use() == 1

      send(pid, :stop)
      wait_until(fn -> AnalysisSlots.in_use() == 0 end)

      assert {_next, :ok} = holder(), "the slot never came back"
    end

    # The thirty-minute timeout kills the task. That has to free the slot too,
    # and it does, because it is the same exit.
    test "a slot comes back when its holder is killed" do
      {pid, :ok} = holder()

      Process.exit(pid, :kill)
      wait_until(fn -> AnalysisSlots.in_use() == 0 end)

      assert {_next, :ok} = holder(), "a killed run held its slot forever"
    end
  end

  defp wait_until(check, remaining \\ 100)

  defp wait_until(_check, 0), do: flunk("condition never became true")

  defp wait_until(check, remaining) do
    if check.() do
      :ok
    else
      Process.sleep(10)
      wait_until(check, remaining - 1)
    end
  end
end
