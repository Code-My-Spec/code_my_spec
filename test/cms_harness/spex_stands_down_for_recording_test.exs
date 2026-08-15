defmodule CmsHarness.SpexStandsDownForRecordingTest do
  @moduledoc """
  The harness reads the recording lock before starting a spex sweep.

  `5a1f6b9c` is fixed by two halves in two different places — the spex suite
  writes `.cms_recording.lock`, and `CmsHarness.Analysis.execute("spex", …)`
  checks it — and the halves cannot see each other. `RecordingLock`'s own tests
  cover the file format and the liveness rule; nothing covered the wiring, and
  the failure mode of bad wiring here is silence.

  That matters more than usual. A lock that never fires looks exactly like a lock
  that fires correctly and is never needed: the sweep runs, the recording is
  corrupted, and the only evidence is 21 rewritten cassettes an hour later. So
  this asserts the path that has to work — `Analysis.run/3` down to the refusal —
  rather than the helper in isolation.

  It is also the cheap half of that path. The refusal returns before
  `Spex.execute/2`, so no `mix` subprocess is spawned and this needs no
  `:analyzer` tag, unlike everything else that drives a real analyzer.

  The pid written is this VM's, so the lock is genuinely live: a test using a
  fake pid would pass against a `skip_reason/1` that ignored liveness entirely.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Analysis
  alias CodeMySpec.RecordingLock

  setup do
    root = CodeMySpec.TempFile.dir("spex-standdown")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{project: %{root: root}, root: root}
  end

  test "refuses the sweep while a live recording holds the working copy", %{
    project: project,
    root: root
  } do
    :ok = RecordingLock.hold(root)

    assert {:error, reason} = Analysis.run(project, "spex")

    assert reason =~ "cassette recording session",
           "the agent has to be able to tell this from a spex failure"

    assert reason =~ System.pid()
    assert reason =~ "clears when that run exits"
  end

  # The other half of the same claim, and the one that would go unnoticed: a
  # working copy with no recording must not be refused. A lock check that
  # refused unconditionally would pass the test above and disable spex entirely.
  #
  # Asserted against the *specific* error an un-onboarded temp directory
  # produces, rather than "either outcome". That is deterministic — the
  # directory is empty by construction — and it is stronger, because it proves
  # the run reached the real analyzer rather than merely that it was not
  # refused for the wrong reason.
  test "runs normally when nothing holds the working copy", %{project: project, root: root} do
    refute File.exists?(RecordingLock.path(root))

    assert {:error, reason} = Analysis.run(project, "spex")

    refute reason =~ "cassette recording session"
    assert reason =~ "has not been onboarded"
  end

  test "a dead holder does not refuse", %{project: project, root: root} do
    File.write!(RecordingLock.path(root), "4194303\n2026-08-15T00:00:00Z\n")

    assert {:error, reason} = Analysis.run(project, "spex")

    refute reason =~ "cassette recording session",
           "a recording killed before its at_exit leaves this file behind; " <>
             "believing it would disable spex with nothing able to clear it"

    assert reason =~ "has not been onboarded"
  end
end
