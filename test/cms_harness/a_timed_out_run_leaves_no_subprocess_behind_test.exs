defmodule CmsHarness.ATimedOutRunLeavesNoSubprocessBehindTest do
  @moduledoc """
  55379e16: the timeout handler used to kill only the supervised Elixir task
  (`Task.Supervisor.terminate_child/2`) and release the slot regardless --
  the shell command it ran stayed alive underneath, once measured at ~296%
  CPU, free to overlap whatever the queue admitted next. SIGTERM alone did
  not stop the one observed live; only SIGKILL did.

  The kill now runs in its own supervised task rather than inline in
  `AnalysisServer`'s own callback, so a confirmation that shells out to `ps`
  and `kill` does not block every other call this project's analyzer queue
  answers. That confirmation is tracked in `pending_cleanups`, independent
  of `running` -- the project's own queue advances to the next entry
  immediately on timeout (only the machine-wide slot, held by the analyzer
  task's own process until it actually dies, needs to wait for the kill;
  `AnalysisSlots` already serializes on that by itself).

  A later test covers the follow-up: `Execution.stop/1`'s own confirmation is
  bounded, but the `ps` call ahead of it is not. If the cleanup task never
  reports back at all, `AnalysisServer` now forces the analyzer task's own
  process dead directly once its own, independent deadline passes -- that is
  what actually frees the machine-wide slot, since a slot is released only
  by the death of the process that acquired it.

  Most tests are driven the same way the sibling `AnalysisServer` tests drive
  `handle_cast/2` (see `a_running_sweep_answers_for_the_next_request_test.exs`):
  a hand-built state and direct calls to the `@impl` callbacks, no real
  channel needed since `project.root` here names none (`Channel.deliver_analysis_result/2`
  logs and returns when `Registry.lookup` finds none). The responsiveness
  test needs a real, running server, since "answers promptly while busy" is
  a property of a live mailbox, not of a function call.

  The task's own shell command writes its child's pid to a file rather than
  returning it as output -- `System.cmd/3` without `:into` only answers once
  it returns, and the whole point here is that it never does.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync

  test "the OS child a timed-out run shelled out to is confirmed dead once cleanup reports" do
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
      pending_cleanups: [],
      timer: nil
    }

    assert {:noreply, mid_state} = AnalysisServer.handle_info({:timeout, 1}, state)

    # The queue already moved on -- there is nothing queued here, so
    # `running` is nil immediately, not held waiting on this run's kill.
    assert mid_state.running == nil
    assert [%{run_id: 1, cleanup: %Task{ref: cleanup_ref}}] = mid_state.pending_cleanups

    assert_receive {^cleanup_ref, cleanup_result}, 6_000

    assert {:noreply, next_state} =
             AnalysisServer.handle_info({cleanup_ref, cleanup_result}, mid_state)

    assert next_state.pending_cleanups == []

    refute_alive(child_pid)
  end

  test "the next queued run starts before its predecessor's kill confirmation reports back" do
    root = "/tmp/a-queue-advances-test-#{System.unique_integer([:positive])}"
    {task, _child_pid} = spawn_hanging_task()

    {:ok, _task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))

    running = %{run_id: 1, source: "exunit", task: task, args: [], tied_run_ids: []}
    next_entry = %{run_id: 2, source: "exunit", tied_run_ids: [], args: [], settled: true}

    state = %{
      project: %{root: root},
      running: running,
      queue: [next_entry],
      pending_cleanups: [],
      timer: nil
    }

    assert {:noreply, next_state} = AnalysisServer.handle_info({:timeout, 1}, state)

    # The queue advanced immediately: `running` is already the next entry,
    # with its own new task, rather than held waiting on the first run's
    # kill confirmation. Only the machine-wide slot (not this project's own
    # queue) still has to wait for that -- `AnalysisSlots` enforces that on
    # its own once the new task calls `acquire/1`.
    assert %{run_id: 2, task: %Task{}} = next_state.running
    assert next_state.queue == []

    # The timed-out run's own cleanup is tracked separately and still
    # pending, not lost in the handoff.
    assert [%{run_id: 1, cleanup: %Task{}}] = next_state.pending_cleanups
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
    # already moved the entry into `pending_cleanups` -- and well before that
    # task's own multi-shell-out confirmation (its first step alone is a
    # `ps` and a `kill` subprocess each) can plausibly have finished and
    # reported back. `idle?/1` now also checks `pending_cleanups`, so it
    # still answers "not idle" even though `running` itself is already nil.
    {elapsed_us, idle?} = :timer.tc(fn -> AnalysisServer.idle?(root) end)

    refute idle?, "the run should still be held (in pending_cleanups) while its kill is confirmed"

    assert elapsed_us < 500_000,
           "idle?/1 took #{elapsed_us}us -- the server's mailbox was blocked behind cleanup " <>
             "confirmation, not answering independently of it"

    refute_alive(child_pid)
  end

  # 55379e16 follow-up, per main's direction: `Analysis.tree_state/1`'s two
  # git calls run between `:slot_acquired` and `:analysis_started` in
  # production (`run_with_slot/3`). A slow one must not eat into the
  # analyzer's own timeout budget -- the kill timer now arms only once
  # `:analysis_started` fires, not at `:slot_acquired`. Simulated here with a
  # real, fixed delay between sending the two messages (what a slow git call
  # would otherwise insert) rather than a short configured timeout raced
  # against wall-clock variance: every assertion reads `:sys.get_state/1`
  # directly, so there is nothing to race.
  test "a slow pre-run git snapshot does not consume any of the analyzer's own timeout window" do
    root = "/tmp/a-slow-snapshot-test-#{System.unique_integer([:positive])}"
    {task, child_pid} = spawn_hanging_task()

    {:ok, _task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))
    {:ok, server} = AnalysisServer.start_link(project: %{root: root})

    running = %{run_id: 1, source: "exunit", task: task, args: [], tied_run_ids: []}
    :sys.replace_state(server, fn state -> %{state | running: running} end)

    send(server, {:slot_acquired, 1, 5})

    # The window a slow pre-run git call would occupy. No timer exists yet,
    # so nothing in the server can fire during it regardless of how long it
    # runs -- checked directly, not inferred from the absence of a crash.
    Process.sleep(200)
    assert :sys.get_state(server).timer == nil

    send(server, {:analysis_started, 1, %{commit: nil, dirty: false}})
    assert is_reference(:sys.get_state(server).timer)

    # The analyzer's own timeout, now fired directly rather than waited out,
    # proves the hanging analyzer is still killed once it actually starts.
    send(server, {:timeout, 1})

    eventually(fn ->
      state = :sys.get_state(server)
      state.running == nil and state.pending_cleanups != []
    end)

    refute_alive(child_pid)
  end

  defp eventually(check, attempts \\ 300), do: eventually(check.(), check, attempts)

  defp eventually(true, _check, _attempts), do: :ok

  defp eventually(false, check, attempts) when attempts > 0 do
    Process.sleep(20)
    eventually(check, attempts - 1)
  end

  defp eventually(false, _check, _attempts), do: flunk("condition never became true")

  test "if the cleanup confirmation never reports back, the analyzer task is killed directly and its bookkeeping clears" do
    root = "/tmp/a-stuck-cleanup-test-#{System.unique_integer([:positive])}"
    {task, _child_pid} = spawn_hanging_task()

    # Registered under this project's own name, the same supervisor
    # `AnalysisServer` itself looks up by root to terminate a stuck cleanup.
    {:ok, task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))

    # Never returns and never crashes -- standing in for `Execution.stop/1`
    # itself hanging inside its own unbounded `ps` call, which this deadline
    # exists to recover from regardless of why the cleanup never reports.
    stuck_cleanup = Task.Supervisor.async_nolink(task_sup, fn -> Process.sleep(:infinity) end)

    pending = %{
      run_id: 1,
      source: "exunit",
      args: [],
      tied_run_ids: [],
      cleanup: stuck_cleanup,
      cleanup_timer: nil
    }

    state = %{
      project: %{root: root},
      running: nil,
      queue: [],
      pending_cleanups: [pending],
      timer: nil
    }

    assert {:noreply, next_state} =
             AnalysisServer.handle_info({:cleanup_overdue, 1, task.pid}, state)

    # What this path actually guarantees: the analyzer task's own Elixir
    # process dies (which is what frees its `AnalysisSlots` slot -- a slot
    # is released by that process's death, nothing else), and its entry is
    # dropped from `pending_cleanups`. It does NOT re-walk the OS process
    # tree -- that walk is exactly what `Execution.stop/1` was stuck inside,
    # so trusting another one here would risk the same hang. A detached
    # grandchild (like this test's backgrounded `sleep`, reparented once its
    # own shell dies) can outlive it; the delivered diagnostic says so
    # rather than claiming confirmed cleanup it cannot back up.
    assert next_state.pending_cleanups == []
    refute Process.alive?(task.pid)
    refute Process.alive?(stuck_cleanup.pid)
  end

  test "a stray overdue message for a run already resolved is ignored" do
    state = %{
      project: %{root: "/tmp/not-used"},
      running: nil,
      queue: [],
      pending_cleanups: [],
      timer: nil
    }

    assert {:noreply, ^state} =
             AnalysisServer.handle_info({:cleanup_overdue, 1, self()}, state)
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
