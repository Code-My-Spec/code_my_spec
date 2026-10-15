defmodule CmsHarness.ATimedOutRunLeavesNoSubprocessBehindTest do
  @moduledoc """
  55379e16: the timeout handler used to kill only the supervised Elixir task
  (`Task.Supervisor.terminate_child/2`) and release the slot regardless --
  the shell command it ran stayed alive underneath, once measured at ~296%
  CPU, free to overlap whatever the queue admitted next. SIGTERM alone did
  not stop the one observed live; only SIGKILL did.

  Driven the same way the sibling `AnalysisServer` tests drive `handle_cast/2`
  (see `a_running_sweep_answers_for_the_next_request_test.exs`): a hand-built
  state and a direct call to the `@impl` callback, no real channel or queue
  needed since the queue here is empty and `project.root` names no running
  channel to push to (`Channel.deliver_analysis_result/2` logs and returns
  when `Registry.lookup` finds none).

  The task's own shell command writes its child's pid to a file rather than
  returning it as output -- `System.cmd/3` without `:into` only answers once
  it returns, and the whole point here is that it never does.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  test "the OS child a timed-out run shelled out to is confirmed dead, not just the task" do
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

    child_pid = wait_for_pid_file(pid_file)

    state = %{
      project: %{root: "/tmp/a-timed-out-run-test-#{System.unique_integer([:positive])}"},
      running: %{run_id: 1, source: "exunit", task: task, args: [], tied_run_ids: []},
      queue: [],
      timer: nil
    }

    assert {:noreply, next_state} = AnalysisServer.handle_info({:timeout, 1}, state)
    assert next_state.running == nil

    {_output, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
    refute status == 0, "child pid #{child_pid} is still alive after the timeout handler ran"
  end

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
