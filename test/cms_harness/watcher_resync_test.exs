defmodule CmsHarness.WatcherResyncTest do
  @moduledoc """
  The watcher syncs on events, and only on events.

  It used to also sync on a 90s floor, added after drill 8 spent its last
  forty-five minutes writing files nobody saw: the process was alive,
  `watching?` was true, `inotifywait` was running against the right
  directories — and no event arrived, so no sync ran, so the requirement graph
  froze while the agent kept working against it. A `touch` hours later
  reconciled all 165 files at once.

  The floor is gone, because the cost got measured: it re-scanned and
  re-uploaded the entire working copy whether or not anything had changed, and
  together with a read-model refresh doing the same it meant a full sync every
  ~30 seconds per copy. That is a lot of work, and a lot of database writes, to
  establish that nothing happened.

  So the guard against drill 8 is now the second test here alone — an event
  this process cannot account for is said out loud rather than dropped, which
  is what makes a broken stream visible. That is a deliberately weaker
  guarantee than a floor, and it is worth knowing which one is protecting us.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.Project.Watcher

  test "a stray :resync from a harness mid-upgrade is ignored, not a crash" do
    state = %Watcher{project: %{id: "p", root: "/tmp/x"}, watching?: true}

    assert {:noreply, ^state} = Watcher.handle_info(:resync, state),
           "the timer is gone, but a message sent before the upgrade can still " <>
             "arrive after it, and killing the watcher over it would take the " <>
             "working copy down with it"
  end

  test "a file event from an untracked pid is logged, not swallowed" do
    state = %Watcher{project: %{id: "p", root: "/tmp/x"}, fs_pid: self(), watching?: true}
    stranger = spawn(fn -> :ok end)

    log =
      capture_log(fn ->
        assert {:noreply, ^state} =
                 Watcher.handle_info({:file_event, stranger, {"/tmp/x/a.ex", [:modified]}}, state)
      end)

    assert log =~ "not delivering",
           "dropping it silently is indistinguishable from a project where " <>
             "nothing changed, which is exactly how this went unnoticed — and " <>
             "with the floor removed, this is the only thing that would show it"
  end

  describe "the liveness check (aac6356e)" do
    test "a stream that has delivered nothing since it started watching is reported" do
      state = %Watcher{
        project: %{id: "p", root: "/tmp/x"},
        watching?: true,
        last_activity_at: System.monotonic_time(:millisecond) - :timer.minutes(10),
        quiet_logged?: false
      }

      log =
        capture_log(fn ->
          assert {:noreply, new_state} = Watcher.handle_info(:liveness_check, state)
          assert new_state.quiet_logged?
          assert new_state.liveness_timer
        end)

      assert log =~ "no filesystem events delivered",
             "watching? staying true while nothing arrives is exactly the state " <>
               "aac6356e found invisible — this is the only thing that says so"
    end

    test "does not re-log every tick once a quiet stretch has already been reported" do
      state = %Watcher{
        project: %{id: "p", root: "/tmp/x"},
        watching?: true,
        last_activity_at: System.monotonic_time(:millisecond) - :timer.minutes(10),
        quiet_logged?: true
      }

      log = capture_log(fn -> Watcher.handle_info(:liveness_check, state) end)

      refute log =~ "no filesystem events delivered",
             "a project that stays quiet for hours should log once, not on every " <>
               "5-minute tick — the point is a grep-able line, not a firehose"
    end

    test "a recent event means nothing is logged" do
      state = %Watcher{
        project: %{id: "p", root: "/tmp/x"},
        watching?: true,
        last_activity_at: System.monotonic_time(:millisecond),
        quiet_logged?: false
      }

      log = capture_log(fn -> Watcher.handle_info(:liveness_check, state) end)

      refute log =~ "no filesystem events delivered",
             "a project that just delivered an event is not the failure this guards against"
    end

    test "a real event arriving after a reported quiet stretch resets it" do
      state = %Watcher{
        project: %{id: "p", root: "/tmp/x"},
        fs_pid: self(),
        watching?: true,
        last_activity_at: System.monotonic_time(:millisecond) - :timer.minutes(10),
        quiet_logged?: true
      }

      assert {:noreply, new_state} =
               Watcher.handle_info({:file_event, self(), {"/tmp/x/a.ex", [:removed]}}, state)

      refute new_state.quiet_logged?,
             "the stream proved itself alive; the next quiet stretch deserves its own report"
    end

    test "a watcher that is not watching does not reschedule itself" do
      state = %Watcher{project: %{id: "p", root: "/tmp/x"}, watching?: false}

      assert {:noreply, ^state} = Watcher.handle_info(:liveness_check, state)
    end
  end
end
