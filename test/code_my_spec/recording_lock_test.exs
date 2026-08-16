defmodule CodeMySpec.RecordingLockTest do
  @moduledoc """
  The lock is only believed while its holder is alive.

  `5a1f6b9c` asks for a lock so a queued spex rerun cannot land on a recording
  session. The hazard in granting that is the opposite one: a lock that outlives
  its holder disables the spex analyzer permanently, and this codebase has a run
  of issues about a guard that wedges and whose own remedy cannot clear it —
  `33fe5b19`, `6f89b278`, `6b3351cb`. A recording session killed mid-run (which
  is how they end when a provider hangs) leaves the file behind, so that is the
  ordinary case, not the exotic one.

  Hence liveness rather than a timestamp or a timeout: it needs no threshold to
  tune and cannot be wrong in the direction that wedges.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.RecordingLock

  setup do
    root = CodeMySpec.TempFile.dir("recording-lock-test")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write_lock(root, pid), do: File.write!(RecordingLock.path(root), "#{pid}\n2026-08-15T00:00:00Z\n")

  test "no lock file means nothing is holding the working copy", %{root: root} do
    assert RecordingLock.holder(root) == :free
    assert RecordingLock.skip_reason(root) == nil
  end

  test "a live holder holds it", %{root: root} do
    write_lock(root, System.pid())

    assert {:held, pid, "2026-08-15T00:00:00Z"} = RecordingLock.holder(root)
    assert pid == System.pid()
  end

  # The case that decides whether this is safe to ship.
  test "a holder that is gone is not a holder", %{root: root} do
    # A pid that cannot be running: allocated far above the machine's maximum
    # and never reachable by recycling within a test run.
    write_lock(root, "4194303")

    assert RecordingLock.holder(root) == :free,
           "a recording session killed before its at_exit leaves this file behind, and " <>
             "believing it would disable the spex analyzer with no way to clear it"

    assert RecordingLock.skip_reason(root) == nil
  end

  test "an unreadable or malformed lock is treated as free", %{root: root} do
    File.write!(RecordingLock.path(root), "")
    assert RecordingLock.holder(root) == :free

    File.write!(RecordingLock.path(root), "not-a-pid\nwhenever\n")
    assert RecordingLock.holder(root) == :free
  end

  test "the skip reason names the holder and says it clears itself", %{root: root} do
    write_lock(root, System.pid())

    reason = RecordingLock.skip_reason(root)

    assert reason =~ System.pid()
    assert reason =~ "2026-08-15T00:00:00Z"

    assert reason =~ "clears when that run exits",
           "an agent reading this in a stop response has to be able to tell it apart " <>
             "from a defect it is expected to fix"
  end

  describe "hold/1" do
    test "writes this VM's pid, and is idempotent", %{root: root} do
      assert RecordingLock.hold(root) == :ok

      assert {:held, pid, _} = RecordingLock.holder(root)
      assert pid == System.pid()

      # Second call is a no-op rather than a rewrite — once per BEAM, like
      # clear_cassette_once/2.
      assert RecordingLock.hold(root) == :ok
      assert {:held, ^pid, _} = RecordingLock.holder(root)
    end
  end
end
