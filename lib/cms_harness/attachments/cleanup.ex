defmodule CmsHarness.Attachments.Cleanup do
  @moduledoc false

  alias CmsHarness.Agents.Engine.Execution

  def stop(pid) do
    case :os.type() do
      {:win32, _} -> stop_windows(pid)
      _ -> Execution.stop_and_release(pid)
    end
  end

  # Desktop's taskkill tree strategy, with owned PIDs and a bounded wait.
  # Desktop itself is not linked into the standalone harness release.
  defp stop_windows(pid) do
    ownership = Execution.capture(pid)

    try do
      Enum.reduce_while(ownership.groups, :ok, fn os_pid, :ok ->
        case kill_windows_tree(os_pid) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    after
      Execution.release(ownership)
    end
  end

  defp kill_windows_tree(pid) do
    task =
      Task.async(fn ->
        System.cmd("taskkill", ["/PID", Integer.to_string(pid), "/T", "/F"],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      other -> {:error, {:process_tree_cleanup_unconfirmed, pid, inspect(other)}}
    end
  end
end
