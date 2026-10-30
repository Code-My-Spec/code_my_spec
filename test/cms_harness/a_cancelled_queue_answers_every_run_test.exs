defmodule CmsHarness.ACancelledQueueAnswersEveryRunTest do
  @moduledoc """
  Cancelling a project's analyzer queue stops the run under way and answers it,
  the runs tied to it, and everything queued, as superseded.

  The promotion gate asks for this when a batch leaves its copy: an ejected
  batch's exunit ran on for thirty minutes under the next batch's reset,
  holding a machine-wide slot (2026-10-12). Every request is still answered,
  as everywhere else in the queue.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  setup do
    root = "/tmp/cancel-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    start_supervised!({Task.Supervisor, name: CmsHarness.Sync.task_supervisor(root)})
    %{root: root}
  end

  defp running_exunit(root) do
    task =
      Task.Supervisor.async_nolink(CmsHarness.Sync.task_supervisor(root), fn ->
        receive do
          :never -> :ok
        end
      end)

    %{source: "exunit", run_id: 1, tied_run_ids: [3], task: task, args: []}
  end

  test "the run under way is stopped and every held run is answered as superseded", %{
    root: root
  } do
    running = running_exunit(root)
    monitor = Process.monitor(running.task.pid)

    state = %{
      project: %{root: root},
      running: running,
      queue: [%{source: "spex", run_id: 2, tied_run_ids: [], args: []}],
      timer: nil
    }

    assert {:reply, 2, after_cancel} =
             AnalysisServer.handle_call({:cancel, "the batch left the gate"}, self(), state)

    assert %{running: nil, queue: []} = after_cancel
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    for run_id <- [1, 3, 2] do
      assert_receive {:"$gen_cast",
                      {:analysis_result,
                       %{
                         "run_id" => ^run_id,
                         "status" => "superseded",
                         "error" => "the batch left the gate"
                       }}}
    end
  end

  test "an idle queue has nothing to cancel", %{root: root} do
    state = %{project: %{root: root}, running: nil, queue: [], timer: nil, recovering: %{}}
    assert {:reply, 0, ^state} = AnalysisServer.handle_call({:cancel, "why"}, self(), state)
    refute_received {:"$gen_cast", {:analysis_result, _}}
  end
end
