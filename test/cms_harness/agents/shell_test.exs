defmodule CmsHarness.Agents.ShellTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Shell

  setup do
    previous = System.get_env("CMS_SHELL_TEST_PROBE")
    System.put_env("CMS_SHELL_TEST_PROBE", "leaked")

    on_exit(fn ->
      if previous,
        do: System.put_env("CMS_SHELL_TEST_PROBE", previous),
        else: System.delete_env("CMS_SHELL_TEST_PROBE")
    end)
  end

  test "an agent's command sees neither MIX_ENV nor the harness's CMS_ variables", %{tmp_dir: dir} do
    {out, 0} = Shell.run(~s(echo "${MIX_ENV:-unset} ${CMS_SHELL_TEST_PROBE:-unset}"), dir)
    assert String.trim(out) == "unset unset"
  end

  test "it still runs in the given directory and keeps other variables", %{tmp_dir: dir} do
    {out, 0} = Shell.run("pwd; echo ${HOME:+home-set}", dir)
    assert out =~ Path.basename(dir)
    assert out =~ "home-set"
  end

  @moduletag :tmp_dir
end
