defmodule CmsHarness.Agents.ShellTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Shell

  # The CMS probe is this test's own. MIX_ENV is put back as it was; the
  # module is sync, so no async test reads it meanwhile.
  setup do
    mix_env = System.get_env("MIX_ENV")
    System.put_env("CMS_SHELL_TEST_PROBE", "leaked")
    System.put_env("MIX_ENV", "harness")

    on_exit(fn ->
      System.delete_env("CMS_SHELL_TEST_PROBE")
      restore("MIX_ENV", mix_env)
    end)
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "an agent's command is run with MIX_ENV and the harness's CMS_ variables unset" do
    unset = Shell.scrubbed_env()

    assert {"CMS_SHELL_TEST_PROBE", nil} in unset
    assert {"MIX_ENV", nil} in unset
  end

  test "a timed-out command returns output already printed" do
    bash = Enum.find(CmsHarness.Agents.Engine.Impl.tools([]), &(&1.name() == "bash"))

    assert {:error, output} =
             bash.execute(
               %{"command" => "echo timeout-output-marker; sleep 2", "timeout" => 500},
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
    assert {:error, output} = Shell.run("printf partial-marker; sleep 2", nil, 500)
    assert output =~ "timed out"
    assert output =~ "partial-marker"
    refute output =~ "exit code:"
  end

  test "it leaves every other variable alone" do
    names = for {name, nil} <- Shell.scrubbed_env(), do: name

    refute "HOME" in names
    refute "PATH" in names
    assert Enum.all?(names, &(&1 == "MIX_ENV" or String.starts_with?(&1, "CMS_")))
  end
end
