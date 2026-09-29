defmodule CmsHarness.Agents.ShellTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Shell

  # The CMS probe is this test's own. MIX_ENV is put back as it was; the
  # module is sync, so no async test reads it meanwhile.
  setup do
    mix_env = System.get_env("MIX_ENV")
    System.put_env("CMS_SHELL_TEST_PROBE", "leaked")
    System.put_env("MIX_ENV", "dev_cli")

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

  test "it leaves every other variable alone" do
    names = for {name, nil} <- Shell.scrubbed_env(), do: name

    refute "HOME" in names
    refute "PATH" in names
    assert Enum.all?(names, &(&1 == "MIX_ENV" or String.starts_with?(&1, "CMS_")))
  end
end
