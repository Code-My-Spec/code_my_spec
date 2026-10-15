defmodule CmsHarness.ATimedOutRunLeavesNoSubprocessBehindTest do
  @moduledoc """
  55379e16: the timeout handler used to kill only the supervised Elixir task
  (`Task.Supervisor.terminate_child/2`) and release the slot regardless --
  the shell command it ran stayed alive underneath, once measured at ~296%
  CPU, free to overlap whatever the queue admitted next. SIGTERM alone did
  not stop the one observed live; only SIGKILL did.

  Confirming the kill now runs in its own supervised task rather than inline
  in `AnalysisServer`'s own callback, so a 5s-bounded `ps`/`kill` confirmation
  does not block every other call this project's analyzer queue answers.
  `running` carries that cleanup task until it reports back, so the queue
  does not advance until the kill is actually confirmed -- the two tests
  below check each half of that separately.

  The first test is driven the same way the sibling `AnalysisServer` tests
  drive `handle_cast/2` (see `a_running_sweep_answers_for_the_next_request_test.exs`):
  a hand-built state and direct calls to the `@impl` callbacks, no real
  channel needed since `project.root` here names none (`Channel.deliver_analysis_result/2`
  logs and returns when `Registry.lookup` finds none). The second test needs
  a real, running server, since "answers promptly while busy" is a property
  of a live mailbox, not of a function call.

  The task's own shell command writes its child's pid to a file rather than
  returning it as output -- `System.cmd/3` without `:into` only answers once
  it returns, and the whole point here is that it never does.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync

  test "the OS child a timed-out run shelled out to is confirmed dead before the queue advances" do
    root = "/tmp/a-timed-out-run-test-#{System.unique_integer([:positive])}"
    {task, child_pid} = spawn_hanging_task()

    # The handler's cleanup task runs under this project's own task
    # supervisor (`Sync.task_supervisor/1`), the same one a real project's
    # supervision tree provides -- a fake root has none unless started here.
    {:ok, _task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))

    state = %{
      project: %{root: root},
      running: %{run_id: 1, source: "exunit", task: task, args: [], tied_run_ids: []},
      queue: [],
      timer: nil
    }

    assert {:noreply, mid_state} = AnalysisServer.handle_info({:timeout, 1}, state)
    cleanup_ref = mid_state.running.cleanup.ref

    # The handler itself only starts the cleanup task -- the run is not
    # finished, and `running` is non-nil, until that task reports back.
    assert mid_state.running.cleanup

    assert_receive {^cleanup_ref, cleanup_result}, 6_000

    assert {:noreply, next_state} =
             AnalysisServer.handle_info({cleanup_ref, cleanup_result}, mid_state)

    assert next_state.running == nil

    refute_alive(child_pid)
  end

  test "while a timed-out run's kill is being confirmed, the server still answers other calls" do
    root = "/tmp/a-timed-out-responsive-test-#{System.unique_integer([:positive])}"
    {task, child_pid} = spawn_hanging_task()

    {:ok, _task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))
    {:ok, server} = AnalysisServer.start_link(project: %{root: root})

    :sys.replace_state(server, fn state ->
      %{state | running: %{run_id: 1, source: "exunit", task: task, args: [], tied_run_ids: []}}
    end)

    send(server, {:timeout, 1})

    # No sleep: messages from one sender to one receiver are delivered in
    # send order on the BEAM, so this `idle?/1` call (sent immediately after,
    # from this same process) is guaranteed to be processed after `:timeout`
    # already started the cleanup task -- and well before that task's own
    # multi-shell-out confirmation (its first step alone is a `ps` and a
    # `kill` subprocess each) can plausibly have finished and reported back.
    {elapsed_us, idle?} = :timer.tc(fn -> AnalysisServer.idle?(root) end)

    refute idle?, "the run should still be held while its kill is being confirmed"

    assert elapsed_us < 500_000,
           "idle?/1 took #{elapsed_us}us -- the server's mailbox was blocked behind cleanup " <>
             "confirmation (bounded at 5s), not answering independently of it"

    refute_alive(child_pid)
  end

  defp spawn_hanging_task do
    pid_file =
      Path.join(System.tmp_dir!(), "analysis_kill_test_#{System.unique_integer([:positive])}")

    # `async_nolink`, like production's own `run_with_slot/2` spawn -- a plain
    # `Task.async/1` links the caller, and `Execution.stop/1`'s unconditional
    # `Process.exit(task.pid, :kill)` propagates `:killed` through that link
    # to whoever is linked, which would be this test process.
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        System.cmd("bash", ["-c", "sleep 30 & echo $! > #{pid_file}; wait"])
      end)

    {task, wait_for_pid_file(pid_file)}
  end

  defp refute_alive(child_pid), do: assert_eventually_dead(child_pid)

  defp assert_eventually_dead(pid, attempts \\ 300),
    do: assert_eventually_dead(dead?(pid), pid, attempts)

  defp dead?(pid) do
    {_output, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    status != 0
  end

  defp assert_eventually_dead(true, _pid, _attempts), do: :ok

  defp assert_eventually_dead(false, pid, attempts) when attempts > 0 do
    Process.sleep(20)
    assert_eventually_dead(pid, attempts - 1)
  end

  defp assert_eventually_dead(false, pid, _attempts),
    do: flunk("child pid #{pid} is still alive 6s after the timeout handler ran")

  defp wait_for_pid_file(path, attempts \\ 50),
    do: wait_for_pid_file(File.exists?(path), path, attempts)

  defp wait_for_pid_file(true, path, _attempts), do: path |> File.read!() |> String.trim()

  defp wait_for_pid_file(false, path, attempts) when attempts > 0 do
    Process.sleep(20)
    wait_for_pid_file(path, attempts - 1)
  end

  defp wait_for_pid_file(false, path, _attempts),
    do: flunk("the task's shell never wrote its child's pid to #{path}")
end
