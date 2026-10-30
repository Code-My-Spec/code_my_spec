defmodule CodeMySpec.ExecutionContexts.LocalGuardTest do
  use ExUnit.Case, async: false

  test "a queued analyzer preserves output and exit status on ordinary completion" do
    env =
      CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, File.cwd!(),
        metadata: %{run_id: 1}
      )

    assert {"answer\n", 7} =
             CodeMySpec.ExecutionContexts.Local.cmd(
               env,
               "/bin/sh",
               ["-c", "printf 'answer\n'; exit 7"],
               stderr_to_stdout: true
             )
  end

  test "a queued analyzer child stops after its harness BEAM is killed" do
    dir = Path.join(System.tmp_dir!(), "local_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    pid_file = Path.join(dir, "child.pid")
    script = Path.join(dir, "runner.exs")

    File.write!(script, """
    env = CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, File.cwd!(), metadata: %{run_id: 1})
    CodeMySpec.ExecutionContexts.Local.cmd(
      env,
      "/bin/sh",
      ["-c", ~s(printf '%s' \"$$\" > \"$CMS_TEST_CHILD_PID_FILE\"; exec /bin/sleep 30)],
      env: [{"CMS_TEST_CHILD_PID_FILE", #{inspect(pid_file)}}],
      stderr_to_stdout: true
    )
    """)

    port =
      Port.open({:spawn_executable, System.find_executable("mix") |> String.to_charlist()}, [
        :binary,
        :exit_status,
        args: [~c"run", ~c"--no-start", String.to_charlist(script)],
        cd: File.cwd!() |> String.to_charlist()
      ])

    {:os_pid, beam_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(beam_pid)], stderr_to_stdout: true)
      File.rm_rf(dir)
    end)

    assert eventually(fn -> File.exists?(pid_file) end)
    child_pid = pid_file |> File.read!() |> String.trim()
    assert {_, 0} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)

    System.cmd("/bin/kill", ["-KILL", Integer.to_string(beam_pid)], stderr_to_stdout: true)

    assert eventually(fn ->
             {state, status} =
               System.cmd("/bin/ps", ["-o", "stat=", "-p", child_pid], stderr_to_stdout: true)

             status != 0 or String.starts_with?(String.trim(state), "Z")
           end)
  end

  defp eventually(fun) do
    Enum.any?(1..80, fn _ ->
      fun.() or
        (
          Process.sleep(100)
          false
        )
    end)
  end
end
