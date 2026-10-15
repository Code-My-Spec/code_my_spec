defmodule CodeMySpecTest.DataCaseTest do
  @moduledoc """
  2aa4c832: `setup_sandbox/1` must wait for a straggling Task started under
  `CodeMySpec.TaskSupervisor` before checking its connection back in, or that
  Task's own DB call (`Agents.dispatch_admitted`'s async branch, among
  others) hits a connection its owner has already released. Reproduced
  directly against `test/code_my_spec/analysis/a_run_a_restart_killed_is_run_again_test.exs`
  before this fix (a logged Postgrex "owner exited" disconnect) and not
  after it; these test the mechanism itself.
  """
  use ExUnit.Case, async: false

  alias CodeMySpecTest.DataCase

  describe "await_background_work/1" do
    test "blocks until a Task started under CodeMySpec.TaskSupervisor finishes" do
      before_snapshot = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
      test_pid = self()

      {:ok, _pid} =
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          Process.sleep(50)
          send(test_pid, :straggler_finished)
        end)

      refute_received :straggler_finished

      DataCase.await_background_work(before_snapshot)

      assert_received :straggler_finished
    end

    test "returns immediately when nothing has started since the snapshot" do
      before_snapshot = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
      started_at = System.monotonic_time(:millisecond)

      assert :ok = DataCase.await_background_work(before_snapshot)
      assert System.monotonic_time(:millisecond) - started_at < 50
    end
  end

  describe "setup_sandbox/1" do
    test "a Task spawned after setup is not already counted in its own snapshot" do
      test_pid = self()

      DataCase.setup_sandbox(%{async: false})

      {:ok, _pid} =
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          Process.sleep(50)
          send(test_pid, :setup_sandbox_straggler_finished)
        end)

      # The drain itself runs at on_exit, after this test body returns, so it
      # cannot be observed from inside the test -- end-to-end coverage is
      # a_run_a_restart_killed_is_run_again_test.exs, which no longer logs the
      # Postgrex "owner exited" disconnect this fix closes. What this proves:
      # setup_sandbox/1 takes its snapshot before this Task exists, so the
      # drain it registers will see this Task as new rather than pre-existing
      # and ignoring it.
      refute_received :setup_sandbox_straggler_finished
    end
  end
end
