defmodule CmsHarness.Agents.RunnerTest do
  @moduledoc """
  Real processes, because the thing under test is whether a process dies.

  Every failure this exists to prevent lives below the abstraction: a signal
  that reached the wrapper and not the agent, a reap that took the parent and
  left its children, a group id that named a stranger after a reboot. A fake
  process would answer whatever the fake was told to answer, and the three
  shipped instances of criterion 2828 all passed their own tests.

  `sleep` is the agent. It is a real process, it spawns real children when asked
  to, and it costs nothing.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Runner

  # Long enough that nothing exits on its own inside a test, short enough that a
  # leaked one is gone before it matters.
  @agent ["-c", "sleep 60"]

  defp in_group(pgid) do
    {out, 0} = System.cmd("ps", ["-eo", "pid,pgid,command"])

    out
    |> String.split("\n")
    |> Enum.filter(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 3) do
        [_pid, group, _cmd] -> group == to_string(pgid)
        _ -> false
      end
    end)
  end

  # Spawning is not instant, and counting before the children exist reads as a
  # group that never had them. Waits on the observable condition rather than
  # guessing a duration: the first version asserted immediately and failed with
  # four processes listed in its own failure message, because the message
  # rendered a moment after the count.
  defp await_group(pgid, at_least, attempts \\ 100)

  defp await_group(pgid, at_least, 0) do
    flunk("group #{pgid} never reached #{at_least} processes; got #{inspect(in_group(pgid))}")
  end

  defp await_group(pgid, at_least, attempts) do
    members = in_group(pgid)

    case length(members) >= at_least do
      true ->
        members

      false ->
        Process.sleep(10)
        await_group(pgid, at_least, attempts - 1)
    end
  end

  defp start_agent(args \\ @agent) do
    {:ok, handle} = Runner.start("/bin/sh", args)
    on_exit(fn -> Runner.stop(handle, grace_ms: 0) end)
    handle
  end

  test "an agent runs in a group of its own" do
    handle = start_agent()

    assert Runner.alive?(handle),
           "the runner reported a handle for a process it cannot see"

    assert [_one] = await_group(handle.pgid, 1)
  end

  test "the group leader is the agent, not a wrapper left behind" do
    handle = start_agent()

    assert [line] = await_group(handle.pgid, 1)

    assert line =~ "sleep",
           "the group leader is not the agent — the wrapper did not `exec`, so " <>
             "there is a process in the tree that nothing accounts for. Got: #{line}"

    refute line =~ "perl",
           "perl is still in the tree, which means it forked instead of exec'ing"
  end

  test "stopping takes what the agent spawned with it" do
    # A parent with two children, which is the shape `pkill -TERM -P` gets
    # wrong: it walks one level and leaves grandchildren behind.
    handle = start_agent(["-c", "sleep 60 & sleep 60 & sleep 60"])

    assert length(await_group(handle.pgid, 3)) >= 3

    assert :ok = Runner.stop(handle)

    assert in_group(handle.pgid) == [],
           "processes the agent spawned outlived the stop, which is the whole " <>
             "reason the group is the unit rather than the pid"
  end

  test "an agent that ignores TERM is killed anyway" do
    # Traps TERM and keeps running — an agent mid-tool-call that will not wind
    # down, or one whose handler is broken.
    handle = start_agent(["-c", "trap '' TERM; sleep 60"])

    assert Runner.alive?(handle)
    assert :ok = Runner.stop(handle, grace_ms: 300)

    refute Runner.alive?(handle),
           "a stop the operator asked for waited on an agent that was never " <>
             "going to answer, and the meter runs the whole time"
  end

  test "stopping reports done only once the group is actually gone" do
    handle = start_agent()

    assert :ok = Runner.stop(handle)
    assert in_group(handle.pgid) == []
    refute Runner.alive?(handle)
  end

  test "a handle from a previous boot is not alive and is never signalled" do
    handle = start_agent()

    stale = %{handle | boot_id: "a-boot-that-has-since-ended"}

    refute Runner.alive?(stale),
           "a group id is only ours if the machine has not rebooted since we " <>
             "recorded it — numbers are reused, and the process holding this " <>
             "one after a reboot belongs to somebody else"

    assert :ok = Runner.stop(stale, grace_ms: 0)

    assert Runner.alive?(handle),
           "stopping a stale handle signalled the group anyway. That is the " <>
             "expensive direction: it kills a stranger's process and nothing " <>
             "would ever trace it back here."
  end

  test "a group id with no boot beside it is refused, not reported stopped" do
    handle = start_agent()

    assert {:error, :no_boot_id} = Runner.stop(%{pgid: handle.pgid, boot_id: nil}, grace_ms: 0),
           "a group id nothing can judge was reported stopped. Both answers are " <>
             "wrong here — signalling may TERM a stranger, and `:ok` says a stop " <>
             "happened over a process that is still spending."

    assert Runner.alive?(handle),
           "the refusal signalled the group anyway"
  end

  test "stopping something already gone is not an error" do
    handle = start_agent()
    assert :ok = Runner.stop(handle)
    assert :ok = Runner.stop(handle)
  end

  describe "boot_id/0" do
    @tag :tmp_dir
    test "carries no field that a clock step can move" do
      id = Runner.boot_id()

      # On Darwin the raw source is `{ sec = 1785496564, usec = 600843 } Fri Jul
      # 31 07:16:04 2026`, and this used to store it whole. `usec` and the date
      # are derived from the current clock — Darwin computes boottime rather
      # than recording it — so a clock step moves them while the machine has
      # plainly not rebooted.
      #
      # That is not cosmetic. `alive?/1` compares this token to a fresh read, so
      # a moved token reports a *live* agent dead, and `stop/2` then declines to
      # signal it. The agent keeps running and keeps costing, which is the exact
      # failure story 1023 exists to prevent — reached by the mechanism meant to
      # make stopping safe.
      refute id =~ "usec",
             "the boot id carries usec, which a clock step moves. Every handle " <>
               "on this machine would read dead and no agent could be stopped. Got: #{id}"

      refute id =~ ~r/\s/,
             "the boot id carries whitespace, so it is the whole sysctl line — " <>
               "including the formatted date, which moves with the clock. Got: #{id}"
    end

    test "is stable across reads within one boot" do
      assert Runner.boot_id() == Runner.boot_id()
    end

    test "matches the boot the machine reports" do
      case :os.type() do
        {:unix, :darwin} ->
          {raw, 0} = System.cmd("sysctl", ["-n", "kern.boottime"])
          [_, seconds] = Regex.run(~r/sec\s*=\s*(\d+)/, raw)

          assert Runner.boot_id() == seconds,
                 "the boot id is not the boot second this machine reports"

        _ ->
          assert is_binary(Runner.boot_id())
      end
    end
  end
end
