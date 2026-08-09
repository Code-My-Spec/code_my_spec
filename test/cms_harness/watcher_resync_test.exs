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
end
