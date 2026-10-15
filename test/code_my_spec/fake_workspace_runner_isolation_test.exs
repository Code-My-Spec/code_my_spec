defmodule CodeMySpecTest.FakeWorkspaceRunnerIsolationTest do
  @moduledoc """
  Issue 7f3a2936 (a concrete instance of 9839ae69): `FakeWorkspaceRunner` used
  to be a single Agent registered under a fixed name, shared by every async
  test that installed it. That produced two failures together: `calls/0`
  (and anything reading it, like `booted_env/0`-style helpers) could return a
  different, concurrently-running test's most recent call instead of this
  test's own; and whichever test's `on_exit` happened to stop the Agent first
  could stop it out from under a sibling still mid-scenario.

  These tests drive two unrelated processes, each installing and using the
  fake independently, the way two concurrently-running async tests would --
  proving their state never crosses -- and a `Task` that installs nothing of
  its own, the way `Workspaces.Boot`'s watcher runs, to prove it still
  resolves to the test that started it rather than to nothing or to another
  test, via `$callers`.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecTest.FakeWorkspaceRunner

  setup do
    {:ok, agent} = FakeWorkspaceRunner.start_link(serving: :erroring)
    # `Process.exit/2` on an already-dead local pid is a no-op, unlike
    # `Agent.stop/1` on one -- the first test stops its agent itself, mid-test.
    on_exit(fn -> Process.exit(agent, :kill) end)
    :ok
  end

  test "two processes installing the fake never see each other's calls or outcomes" do
    FakeWorkspaceRunner.start("mine", "app", 5000)

    task =
      Task.async(fn ->
        {:ok, agent} = FakeWorkspaceRunner.start_link(serving: :down)
        FakeWorkspaceRunner.start("theirs", "app", 5001)
        result = {FakeWorkspaceRunner.serving(5001), container_names(FakeWorkspaceRunner.calls())}
        Agent.stop(agent)
        result
      end)

    assert Task.await(task) == {:down, ["theirs"]},
           "a second process installing its own fake should see only its own outcome and " <>
             "its own calls, never this test's"

    assert FakeWorkspaceRunner.serving(5000) == :erroring,
           "this test's own outcome changed after an unrelated process installed its own fake"

    assert container_names(FakeWorkspaceRunner.calls()) == ["mine"],
           "this test's own calls picked up an unrelated process's call"
  end

  test "a process that installs nothing of its own resolves through $callers, like the boot watcher does" do
    FakeWorkspaceRunner.start("watched", "app", 6000)

    # The same shape as `Workspaces.boot/1`'s own watcher: a Task spawned off
    # the test process under `CodeMySpec.TaskSupervisor`, never installing a
    # fake of its own, calling into the one the test installed.
    result =
      CodeMySpec.TaskSupervisor
      |> Task.Supervisor.async(fn ->
        {FakeWorkspaceRunner.serving(6000), container_names(FakeWorkspaceRunner.calls())}
      end)
      |> Task.await()

    assert result == {:erroring, ["watched"]},
           "a process with no fake of its own, spawned under TaskSupervisor the way the " <>
             "boot watcher is, failed to resolve back to the test that started it"
  end

  test "a process with no fake installed, and no $callers path to one, resolves to the " <>
         "sole fake running -- the same ambient fallback Ecto's own Sandbox gives" do
    parent = self()

    # A bare `spawn`, not a `Task` -- `$callers` is a convention `Task` and
    # `Task.Supervisor` set deliberately, not something every child process
    # inherits, so this one has neither its own registration nor a path back
    # to this test's. This test's `setup` is the only fake installed anywhere
    # right now, so it still resolves rather than raising.
    _pid = spawn(fn -> send(parent, {:result, FakeWorkspaceRunner.serving(7000)}) end)

    assert_receive {:result, :erroring}
  end

  test "two fakes installed with no $callers path to either raises, rather than guessing " <>
         "which one a bare call means" do
    parent = self()

    owner_pid =
      spawn(fn ->
        {:ok, _agent} = FakeWorkspaceRunner.start_link(serving: :down)
        send(parent, :second_fake_installed)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner_pid, :kill) end)

    assert_receive :second_fake_installed

    # A bare `spawn` again -- with this test's own fake AND the one just
    # installed above both live, and no `$callers` chain reaching either,
    # there are two candidates and nothing says which one a bare call means.
    #
    # `spawn_monitor/1`, not `spawn/1` followed by a separate `Process.monitor/1`:
    # the two-step version races the spawned process's own crash -- if it dies
    # before `monitor/1` runs, the monitor is set up against an already-dead
    # pid and Erlang reports `:noproc` instead of the real exit reason.
    {pid, ref} = spawn_monitor(fn -> FakeWorkspaceRunner.serving(8000) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: message}, _stacktrace}}
    assert message =~ "More than one"
  end

  defp container_names(calls), do: Enum.map(calls, fn {name, _app, _port, _env} -> name end)
end
