defmodule CodeMySpecTest.FakeWorkspaceRunnerReinstallTest do
  @moduledoc """
  Installing the fake workspace runner twice in one test process.

  Scenarios inside a single `spex` block share a process. They read as sibling
  blocks and are not, so adding a scenario to an existing criterion — an
  ordinary thing to do — met:

      ** (RuntimeError) failed to start child with the spec
         {CodeMySpecTest.FakeWorkspaceRunner, [...]}.
         Reason: bad child specification, got: {:already_started, #PID<...>}

  That names a child spec and a pid, so it reads as a supervision bug in the
  code under test. The second installer was the caller's own fixture call, and
  finding that took a stacktrace read.
  """
  use ExUnit.Case, async: false

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.FakeWorkspaceRunner

  test "a second install reconfigures rather than colliding" do
    :ok = Fixtures.install_workspace_runner(serving: :serving, healthy?: true)

    assert FakeWorkspaceRunner.serving(4000) == :serving

    # What used to raise.
    :ok = Fixtures.install_workspace_runner(serving: :erroring, healthy?: false)

    assert FakeWorkspaceRunner.serving(4000) == :erroring,
           "the second call's outcomes have to win — that is what installing again means"

    refute FakeWorkspaceRunner.healthy?(4000)
  end

  # Reconfiguring says what the workspace does next. It does not say the context
  # never called `start/3`, and a later scenario asserting on earlier calls is a
  # reasonable thing to write.
  test "recorded calls survive a reconfigure" do
    :ok = Fixtures.install_workspace_runner(serving: :serving)
    FakeWorkspaceRunner.start("container", "app", 4000)

    assert length(FakeWorkspaceRunner.calls()) == 1

    :ok = Fixtures.install_workspace_runner(serving: :down)

    assert length(FakeWorkspaceRunner.calls()) == 1,
           "a reconfigure must not erase what the context already did"
  end
end
