defmodule CodeMySpec.ADurableRunSurvivesItsShellExecTest do
  @moduledoc """
  A durable run's identity was its start time and command line. `sh -c`
  replaces itself with its command, so an identity read before that exec
  never matched again: under load, "cancelling a durable run terminates its
  OS command" found the run already dead (exunit 66174).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.DurableRun

  test "a run attached before its shell execs is still alive after it" do
    id = System.unique_integer([:positive])
    DurableRun.begin_run(id, File.cwd!(), "exunit", [], "abc123")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", "sleep 0.5; exec sleep 30"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      DurableRun.cleanup(id)
    end)

    :ok = DurableRun.attach_pid(id, pid)
    {:ok, manifest} = DurableRun.read_manifest(id)

    assert eventually(fn -> exec_done?(pid) end), "the shell never exec'd its command"
    assert DurableRun.alive?(manifest)
  end

  defp exec_done?(pid) do
    {command, _} = System.cmd("/bin/ps", ["-o", "command=", "-p", Integer.to_string(pid)])
    String.starts_with?(String.trim(command), "sleep")
  end

  defp eventually(fun) do
    Enum.any?(1..50, fn _ ->
      fun.() or
        (
          Process.sleep(20)
          false
        )
    end)
  end
end
