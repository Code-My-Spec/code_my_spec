defmodule CodeMySpecTest.FakeWorkspaceRunnerIsolationTest do
  @moduledoc """
  Issue 7f3a2936 (a concrete instance of 9839ae69): `FakeWorkspaceRunner` used
  to be a single Agent registered under a fixed name, shared by every async
  test that installed it. That produced two failures together: `calls/0`
  (and anything reading it, like `booted_env/0`-style helpers) could return a
  different, concurrently-running test's most recent call instead of this
  test's own; and whichever test's `on_exit` happened to stop the Agent first
  could stop it out from under a sibling still mid-scenario.

  No shared `setup` here, deliberately: each test installs exactly what it
  means to, so the fakes under test are never confused with a pre-installed
  one from a setup block every test would otherwise share.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecTest.FakeWorkspaceRunner

  test "two unrelated processes installing the fake never see each other's calls or outcomes" do
    {:ok, mine} = FakeWorkspaceRunner.start_link(serving: :erroring)
    # `Process.exit/2` on an already-dead local pid is a no-op, unlike
    # `Agent.stop/1` on one -- harmless whether or not the agent is still up.
    on_exit(fn -> Process.exit(mine, :kill) end)
    FakeWorkspaceRunner.start("mine", "app", 5000)

    # A bare `spawn`, not a `Task` -- `Task.async/1` deliberately sets
    # `$callers` to its caller (this test), which is exactly wrong for
    # simulating a second, unrelated test's own identity. A bare `spawn`
    # inherits no `$callers` at all, so its `start_link/1` call registers
    # under its own pid, genuinely distinct from this test's.
    parent = self()

    theirs_pid =
      spawn(fn ->
        {:ok, agent} = FakeWorkspaceRunner.start_link(serving: :down)
        FakeWorkspaceRunner.start("theirs", "app", 5001)

        send(
          parent,
          {:result, FakeWorkspaceRunner.serving(5001), container_names(FakeWorkspaceRunner.calls())}
        )

        Agent.stop(agent)
      end)

    on_exit(fn -> Process.exit(theirs_pid, :kill) end)

    assert_receive {:result, serving, calls}

    assert {serving, calls} == {:down, ["theirs"]},
           "a second, unrelated process installing its own fake should see only its own " <>
             "outcome and its own calls, never this test's"

    assert FakeWorkspaceRunner.serving(5000) == :erroring,
           "this test's own outcome changed after an unrelated process installed its own fake"

    assert container_names(FakeWorkspaceRunner.calls()) == ["mine"],
           "this test's own calls picked up an unrelated process's call"
  end

  test "a Task spawned off this test resolves through $callers, like the boot watcher does" do
    {:ok, agent} = FakeWorkspaceRunner.start_link(serving: :erroring)
    on_exit(fn -> Process.exit(agent, :kill) end)
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

  test "installed the way start_supervised! does it -- $callers set on the caller, not " <>
         "self() -- registers under the test, not under the process that called start_link/1" do
    parent = self()

    # ExUnit's own test supervisor has `$callers` pointing at the test process
    # in its process dictionary (Elixir 1.17+, `ExUnit.Callbacks`), and calls
    # `start_link/1` synchronously from inside itself -- so from `start_link/1`'s
    # point of view, `self()` is that supervisor, not the test. A plain `spawn`
    # with `$callers` set by hand stands in for that supervisor process here.
    helper_pid =
      spawn_as_caller(fn ->
        {:ok, agent} = FakeWorkspaceRunner.start_link(serving: :down)
        send(parent, {:started, agent})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(helper_pid, :kill) end)

    assert_receive {:started, _agent}

    assert FakeWorkspaceRunner.serving(9000) == :down,
           "a fake started via a $callers-only path (the start_supervised! shape) did not " <>
             "register under the test -- this test's own lookup chain could not find it"
  end

  test "a process with no fake installed, and no $callers path to one, raises clearly " <>
         "rather than silently reading an unrelated test's state" do
    # `spawn_monitor/1`, not `spawn/1` followed by a separate `Process.monitor/1`:
    # the two-step version races the spawned process's own crash -- if it dies
    # before `monitor/1` runs, the monitor is set up against an already-dead
    # pid and Erlang reports `:noproc` instead of the real exit reason.
    #
    # A bare `spawn`, not a `Task` -- `$callers` is a convention `Task` and
    # `Task.Supervisor` set deliberately, not something every child process
    # inherits -- so this one has neither its own registration nor a path
    # back to this test's, and this test installs nothing at all.
    {pid, ref} = spawn_monitor(fn -> FakeWorkspaceRunner.serving(7000) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: message}, _stacktrace}}
    assert message =~ "No CodeMySpecTest.FakeWorkspaceRunner installed"
  end

  defp spawn_as_caller(fun) do
    test_pid = self()

    pid =
      spawn(fn ->
        Process.put(:"$callers", [test_pid])
        fun.()
      end)

    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 50
    Process.demonitor(ref, [:flush])
    pid
  end

  defp container_names(calls), do: Enum.map(calls, fn {name, _app, _port, _env} -> name end)
end
