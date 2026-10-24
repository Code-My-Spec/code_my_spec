defmodule CmsHarness.AppInstance.Runner.LocalStopTest do
  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.Runner.Local

  @moduletag skip: match?({:win32, _}, :os.type())

  test "stop confirms that the owned OS process has exited before returning" do
    executable = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: ["-c", "printf ready; read line"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      cleanup_process(pid, Local.alive?(pid))
    end)

    assert_receive {^port, {:data, "ready"}}, 1_000
    assert Local.alive?(pid)
    assert :ok = Local.stop_process(pid)
    refute Local.alive?(pid)
  end

  defp cleanup_process(_pid, false), do: :ok
  defp cleanup_process(pid, true), do: System.cmd("kill", ["-KILL", Integer.to_string(pid)])
end
