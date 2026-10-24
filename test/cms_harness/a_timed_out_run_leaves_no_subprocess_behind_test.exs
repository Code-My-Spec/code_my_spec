defmodule CmsHarness.ATimedOutRunLeavesNoSubprocessBehindTest do
  @moduledoc """
  Timeout cleanup retains the OS groups created at spawn, sends TERM then
  KILL, and confirms termination before releasing the queue or machine-wide slot.
  The real fixture ignores TERM and includes a reparented grandchild.
  Both normal cleanup and overdue recovery must kill both descendants.
  Overdue recovery reports its outcome on the run within the original
  deadline; unsuccessful confirmation identifies observed surviving PIDs.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync

  test "a waiting command starts after descendants die and timeout output survives" do
    alias CmsHarness.AnalysisSlots
    previous_limit = Application.fetch_env(:code_my_spec, :analysis_slots)
    Application.put_env(:code_my_spec, :analysis_slots, 1)

    on_exit(fn -> restore_slot_limit(previous_limit) end)

    eventually(fn -> AnalysisSlots.in_use() == 0 end)
    root = "/tmp/timeout-slot-output-#{Ecto.UUID.generate()}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    {:ok, capture} = StringIO.open("")
    {task, child_pids} = spawn_hanging_task(capture, true)
    {:ok, supervisor} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))

    next_command =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = AnalysisSlots.acquire()

        System.cmd(
          System.find_executable("python3"),
          [
            "-c",
            """
            import os, sys
            survivors = []
            for pid in sys.argv[1:]:
                try:
                    os.kill(int(pid), 0)
                    survivors.append(pid)
                except ProcessLookupError:
                    pass
            if survivors:
                print(' '.join(survivors))
                sys.exit(1)
            """
            | child_pids
          ],
          stderr_to_stdout: true
        )
      end)

    on_exit(fn -> Process.exit(next_command.pid, :kill) end)
    eventually(fn -> AnalysisSlots.waiting() == 1 end)

    state = %{
      project: %{root: root},
      running: %{
        run_id: 1,
        source: "exunit",
        task: task,
        args: [],
        tied_run_ids: [],
        output_capture: capture
      },
      queue: [],
      pending_cleanups: [],
      timer: nil
    }

    assert {:noreply, pending} = AnalysisServer.handle_info({:timeout, 1}, state)
    [%{cleanup: %{ref: ref}}] = pending.pending_cleanups
    assert_receive {^ref, :ok}, 6_000
    assert {:noreply, finished} = AnalysisServer.handle_info({ref, :ok}, pending)
    assert {"", 0} = Task.await(next_command, 6_000)
    assert finished.pending_cleanups == []
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["output"] == "stdout-before-timeout\nstderr-without-newline"
    assert payload["error"] =~ "Subprocess termination confirmed"
    refute_alive(child_pids)
  end

  test "timeout delivers partial output after confirming descendant termination" do
    root = "/tmp/timeout-output-#{Ecto.UUID.generate()}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    {:ok, capture} = StringIO.open("")
    {task, child_pids} = spawn_hanging_task(capture)
    {:ok, _} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))

    state = %{
      project: %{root: root},
      running: %{
        run_id: 1,
        source: "exunit",
        task: task,
        args: [],
        tied_run_ids: [],
        output_capture: capture
      },
      queue: [],
      pending_cleanups: [],
      timer: nil
    }

    assert {:noreply, pending} = AnalysisServer.handle_info({:timeout, 1}, state)
    [%{cleanup: %{ref: ref}}] = pending.pending_cleanups
    assert_receive {^ref, result}, 6_000
    assert result == :ok
    assert {:noreply, finished} = AnalysisServer.handle_info({ref, result}, pending)
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["status"] == "error"
    assert payload["error"] =~ "Subprocess termination confirmed"
    refute_alive(child_pids)
    assert finished.pending_cleanups == []
    assert payload["output"] == "stdout-before-timeout\nstderr-without-newline"
    refute Process.alive?(capture)
  end

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

    # The timed-out entry moves to pending cleanup. Running is nil, but
    # pending cleanup prevents queued work from starting before confirmation.
    assert mid_state.running == nil
    assert [%{run_id: 1, cleanup: %Task{ref: cleanup_ref}}] = mid_state.pending_cleanups

    assert_receive {^cleanup_ref, cleanup_result}, 6_000
    assert cleanup_result == :ok

    assert {:noreply, next_state} =
             AnalysisServer.handle_info({cleanup_ref, cleanup_result}, mid_state)

    assert next_state.pending_cleanups == []

    refute_alive(child_pid)
  end

  test "the next queued run waits for its predecessor's confirmed termination" do
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

    # Neither this queue nor another slot waiter may start work until the
    # timed-out process tree has been confirmed dead.
    assert next_state.running == nil
    assert next_state.queue == [next_entry]
    assert [%{run_id: 1, cleanup: %Task{ref: ref}}] = next_state.pending_cleanups

    assert_receive {^ref, :ok}, 6_000
    assert {:noreply, finished} = AnalysisServer.handle_info({ref, :ok}, next_state)
    assert %{run_id: 2, task: %Task{} = next_task} = finished.running
    assert finished.queue == []
    assert finished.pending_cleanups == []
    Task.Supervisor.terminate_child(Sync.task_supervisor(root), next_task.pid)
    Process.demonitor(next_task.ref, [:flush])
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

  test "overdue cleanup kills the TERM-refusing child and detached grandchild" do
    root = "/tmp/a-stuck-cleanup-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    {task, child_pids} = spawn_hanging_task()
    {:ok, task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))
    stuck_cleanup = Task.Supervisor.async_nolink(task_sup, fn -> Process.sleep(:infinity) end)

    pending = %{
      run_id: 1,
      source: "exunit",
      args: [],
      tied_run_ids: [],
      cleanup: stuck_cleanup,
      cleanup_timer: nil,
      cleanup_ownership: CmsHarness.Agents.Engine.Execution.capture(task.pid),
      cleanup_deadline: System.monotonic_time(:millisecond) + 5_000
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

    assert System.monotonic_time(:millisecond) <= pending.cleanup_deadline
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["run_id"] == 1
    assert payload["status"] == "error"
    assert payload["error"] =~ "Cleanup worker overdue"
    assert payload["error"] =~ "Subprocess termination confirmed"
    refute_alive(child_pids)
    assert next_state.pending_cleanups == []
    refute Process.alive?(task.pid)
    refute Process.alive?(stuck_cleanup.pid)
  end

  test "a crashed cleanup worker still releases the analyzer and kills both descendants" do
    root = "/tmp/a-crashed-cleanup-test-#{Ecto.UUID.generate()}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    {task, child_pids} = spawn_hanging_task()
    {:ok, task_sup} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))
    cleanup = Task.Supervisor.async_nolink(task_sup, fn -> Process.sleep(:infinity) end)
    ownership = CmsHarness.Agents.Engine.Execution.capture(task.pid)
    on_exit(fn -> CmsHarness.Agents.Engine.Execution.stop_owned(ownership) end)
    cleanup_timer = Process.send_after(self(), {:cleanup_overdue, 1, task.pid}, 20_000)

    pending = %{
      run_id: 1,
      source: "exunit",
      args: [],
      tied_run_ids: [],
      cleanup: cleanup,
      cleanup_timer: cleanup_timer,
      cleanup_ownership: ownership,
      cleanup_deadline: System.monotonic_time(:millisecond) + 5_000
    }

    state = %{
      project: %{root: root},
      running: nil,
      queue: [],
      pending_cleanups: [pending],
      timer: nil
    }

    ref = cleanup.ref
    pid = cleanup.pid
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed} = down
    assert {:noreply, next_state} = AnalysisServer.handle_info(down, state)

    assert System.monotonic_time(:millisecond) <= pending.cleanup_deadline
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["run_id"] == 1
    assert payload["status"] == "error"
    assert payload["error"] =~ "cleanup crashed: :killed"
    assert payload["error"] =~ "Subprocess termination confirmed"
    refute_alive(child_pids)
    refute Process.alive?(task.pid)
    refute Process.alive?(cleanup.pid)
    assert next_state.pending_cleanups == []
    assert next_state.running == nil
    assert Process.read_timer(cleanup_timer) == false
  end

  test "unconfirmed group cleanup names the surviving child and detached grandchild" do
    {task, child_pids} = spawn_hanging_task()
    ownership = CmsHarness.Agents.Engine.Execution.capture(task.pid)

    on_exit(fn -> CmsHarness.Agents.Engine.Execution.stop_owned(ownership) end)
    deadline = System.monotonic_time(:millisecond) + 500

    assert {:error, {:subprocess_shutdown_unconfirmed, survivors, _details}} =
             CmsHarness.Agents.Engine.ProcessGroups.confirm(ownership.groups, deadline)

    for pid <- child_pids do
      assert String.to_integer(pid) in survivors
    end

    assert :ok = CmsHarness.Agents.Engine.Execution.stop_owned(ownership)
    refute_alive(child_pids)
  end

  test "failed confirmation retains the owner and queue until a successful retry" do
    alias CmsHarness.Agents.Engine.Execution
    root = "/tmp/cleanup-retry-#{Ecto.UUID.generate()}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    {:ok, supervisor} = Task.Supervisor.start_link(name: Sync.task_supervisor(root))
    task = Task.Supervisor.async_nolink(supervisor, fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(task.pid, :kill) end)
    ownership = Execution.capture(task.pid)
    result = Execution.stop_owned(ownership, System.monotonic_time(:millisecond) - 1)
    assert {:error, _} = result
    assert Process.alive?(task.pid)
    {:ok, capture} = StringIO.open("")
    IO.binwrite(capture, "partial output")
    ref = make_ref()

    pending = %{
      run_id: 1,
      source: "exunit",
      args: [],
      tied_run_ids: [],
      output_capture: capture,
      cleanup: %{ref: ref, pid: task.pid},
      cleanup_timer: nil,
      cleanup_ownership: ownership
    }

    entry = %{run_id: 2, source: "exunit", args: [], tied_run_ids: []}

    state = %{
      project: %{root: root},
      running: nil,
      queue: [entry],
      pending_cleanups: [pending],
      timer: nil
    }

    assert {:noreply, blocked} = AnalysisServer.handle_info({ref, result}, state)
    assert blocked.running == nil
    assert blocked.queue == [entry]
    assert Process.alive?(task.pid)
    assert_receive {:"$gen_cast", {:analysis_result, payload}}
    assert payload["output"] == "partial output"
    [retry] = blocked.pending_cleanups
    Process.cancel_timer(retry.cleanup_timer)
    # The completed cleanup worker is distinct from the retained analyzer.
    retry = Map.put(retry, :cleanup, nil)
    blocked = %{blocked | pending_cleanups: [retry]}

    assert {:noreply, finished} =
             AnalysisServer.handle_info({:cleanup_overdue, 1, task.pid}, blocked)

    assert finished.pending_cleanups == []
    assert %{run_id: 2, task: next_task} = finished.running
    eventually(fn -> not Process.alive?(task.pid) end)
    refute_receive {:"$gen_cast", {:analysis_result, _}}
    Task.Supervisor.terminate_child(supervisor, next_task.pid)
    Process.demonitor(next_task.ref, [:flush])
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

  defp spawn_hanging_task(capture \\ nil, hold_slot \\ false) do
    pid_file =
      Path.join(System.tmp_dir!(), "analysis_kill_test_#{Ecto.UUID.generate()}")

    # `async_nolink`, like production's own `run_with_slot/2` spawn -- a plain
    # `Task.async/1` links the caller, and `Execution.stop/1`'s unconditional
    # `Process.exit(task.pid, :kill)` propagates `:killed` through that link
    # to whoever is linked, which would be this test process.
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = acquire_fixture_slot(hold_slot)
        env = CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, File.cwd!())

        CodeMySpec.ExecutionContexts.cmd(
          env,
          System.find_executable("python3"),
          [
            "-c",
            """
            import os, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = os.fork()
            if child == 0:
                time.sleep(30)
                os._exit(0)
            read_fd, write_fd = os.pipe()
            middle = os.fork()
            if middle == 0:
                os.close(read_fd)
                grandchild = os.fork()
                if grandchild == 0:
                    os.close(write_fd)
                    time.sleep(30)
                    os._exit(0)
                os.write(write_fd, str(grandchild).encode())
                os.close(write_fd)
                os._exit(0)
            os.close(write_fd)
            grandchild = int(os.read(read_fd, 64))
            os.close(read_fd)
            os.waitpid(middle, 0)
            os.write(1, b"stdout-before-timeout\\n")
            os.write(2, b"stderr-without-newline")
            with open(sys.argv[1] + ".pending", "w") as output:
                output.write(str(child) + " " + str(grandchild))
            os.replace(sys.argv[1] + ".pending", sys.argv[1])
            time.sleep(30)
            """,
            pid_file
          ],
          stderr_to_stdout: true,
          output_capture: capture
        )
      end)

    pids = pid_file |> wait_for_pid_file() |> String.split()

    on_exit(fn ->
      Enum.each(pids, fn pid ->
        System.cmd("/bin/kill", ["-KILL", pid], stderr_to_stdout: true)
      end)

      File.rm(pid_file)
    end)

    {task, pids}
  end

  defp restore_slot_limit({:ok, value}),
    do: Application.put_env(:code_my_spec, :analysis_slots, value)

  defp restore_slot_limit(:error),
    do: Application.delete_env(:code_my_spec, :analysis_slots)

  defp acquire_fixture_slot(true), do: CmsHarness.AnalysisSlots.acquire()
  defp acquire_fixture_slot(false), do: :ok

  defp refute_alive(child_pids), do: Enum.each(child_pids, &assert_eventually_dead/1)

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
