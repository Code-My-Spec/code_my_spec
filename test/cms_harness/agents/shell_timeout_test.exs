defmodule CmsHarness.Agents.ShellTimeoutTest do
  # Async: each timeout waits out its deadline, and only overlapping hides it.
  # Nothing here touches the environment the sync `ShellTest` changes.
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.Impl
  alias CmsHarness.Agents.Shell

  test "a timed-out command returns output already printed" do
    bash = Enum.find(Impl.tools([]), &(&1.name() == "bash"))

    assert {:error, output} =
             bash.execute(
               %{"command" => "echo timeout-output-marker; sleep 10", "timeout" => 3000},
               %{bash_executor: &Shell.run/2, bash_restricted: true}
             )

    assert output =~ "timed out"
    assert output =~ "timeout-output-marker"
    refute output =~ "exit code: 0"
  end

  test "completed commands retain stdout, stderr and their exit status" do
    assert {:ok, output} =
             Shell.run("echo stdout-marker; echo stderr-marker >&2; exit 7", nil, 5_000)

    assert output =~ "stdout-marker"
    assert output =~ "stderr-marker"
    assert output =~ "exit code: 7"
  end

  test "timeout retains output without a trailing newline" do
    assert {:error, output} = Shell.run("printf partial-marker; sleep 30", nil, 3_000)
    assert output =~ "timed out"
    assert output =~ "partial-marker"
    refute output =~ "exit code:"
  end

  test "timeout terminates the command's own child process" do
    assert {:error, output} =
             Shell.run("sleep 30 & child=$!; echo child-pid:$child; wait $child", nil, 3_000)

    assert output =~ "Local command subprocess termination confirmed"
    [_, child] = Regex.run(~r/child-pid:(\d+)/, output)
    {_output, status} = System.cmd("/bin/kill", ["-0", child], stderr_to_stdout: true)
    refute status == 0
  end
end
