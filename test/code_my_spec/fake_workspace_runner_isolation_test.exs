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
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
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

  test "a process with no fake of its own and no path back to one raises, rather than " <>
         "silently reading an unrelated test's state" do
    parent = self()

    # A bare `spawn`, not a `Task` -- `$callers` is a convention `Task` and
    # `Task.Supervisor` set deliberately, not something every child process
    # inherits, so this one has neither its own registration nor a path back
    # to this test's.
    pid =
      spawn(fn ->
        result =
          try do
            {:ok, FakeWorkspaceRunner.serving(7000)}
          rescue
            e -> {:raised, e}
          end

        send(parent, {:result, result})
      end)

    ref = Process.monitor(pid)

    assert_receive {:result, {:raised, %RuntimeError{}}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp container_names(calls), do: Enum.map(calls, fn {name, _app, _port, _env} -> name end)
end
