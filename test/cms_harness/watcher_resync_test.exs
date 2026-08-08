defmodule CmsHarness.WatcherResyncTest do
  @moduledoc """
  The watcher syncs on a timer as well as on events.

  Drill 8 spent its last forty-five minutes writing files nobody saw. The
  process was alive, `watching?` was true, `inotifywait` was running against the
  right directories — and no event arrived, so no sync ran, so the requirement
  graph froze while the agent kept working against it and had no way to tell.
  A single `touch` hours later reconciled all 165 files at once: nothing had
  been lost, and nothing had been looked at either.

  These do not assert a root cause, because it is not known. They assert that
  not knowing it stops mattering: a sync happens on a schedule regardless, and a
  file event this process cannot account for is said out loud rather than
  dropped.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.Project.Watcher

  test "the resync interval is a floor, not a retry" do
    interval = Watcher.resync_interval_ms()

    assert interval > 0

    assert interval <= 300_000,
           "this number is the ceiling on how long a frozen watcher can hide, " <>
             "and an agent works through several requirements in five minutes"
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
             "nothing changed, which is exactly how this went unnoticed"
  end
end
