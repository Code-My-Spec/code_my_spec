defmodule CmsHarness.AgentPrerequisitesTest do
  use ExUnit.Case, async: false
  alias CmsHarness.Setup.Prerequisites

  setup do
    root = Path.join(System.tmp_dir!(), "agent-prereqs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = System.get_env("PATH")
    System.put_env("PATH", root)

    on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp executable(root, name, script) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o700)
  end

  test "uses each CLI's version command without requiring the development stack", %{root: root} do
    executable(root, "codex", "[ \"$*\" = '--version' ] || exit 1\nprintf 'codex 1.0\\n'\n")
    executable(root, "claude", "[ \"$*\" = '-v' ] || exit 1\nprintf 'Claude Code 1.0\\n'\n")

    assert %{"codex" => %{installed?: true}, "claude" => %{installed?: true}} =
             Prerequisites.agent_installations(root)

    refute File.exists?(Path.join(root, "setup"))
  end

  test "nonzero exits and empty version output are unavailable", %{root: root} do
    executable(root, "codex", "printf 'broken\\n'\nexit 1\n")
    executable(root, "claude", "exit 0\n")
    results = Prerequisites.agent_installations(root)
    assert %{installed?: false, error: codex_error} = results["codex"]
    assert codex_error =~ "status 1"
    assert %{installed?: false, error: claude_error} = results["claude"]
    assert claude_error =~ "no version information"
  end
end
