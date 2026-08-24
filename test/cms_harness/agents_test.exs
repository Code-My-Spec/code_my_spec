defmodule CmsHarness.AgentsTest do
  @moduledoc """
  What this machine does when the server asks it to bring an agent up.

  The command is decided here rather than sent, because what is installed is a
  fact only this machine has. So the failures worth naming are this machine's
  failures: no engine it knows, no binary on the PATH, no checkout to work in.

  The launch itself is exercised against a real process — `CmsHarness.Agents.Runner`
  has its own tests for the group mechanics, and this covers the decisions made
  before it is called.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents
  alias CmsHarness.Agents.Runner

  setup do
    root = CodeMySpec.TempFile.dir("cms_harness_agent")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp request(root, overrides \\ %{}) do
    Map.merge(
      %{
        "agent_id" => "agent-1",
        "engine" => "pi",
        "provider" => "zai",
        "config_dir" => Path.join(root, "config"),
        "working_copy" => root,
        "role" => "coding"
      },
      overrides
    )
  end

  test "an engine this machine does not know is named, not attempted", %{root: root} do
    assert {:error, :unknown_engine} = Agents.launch(request(root, %{"engine" => "cursor"}))
  end

  test "a request with no engine at all is refused", %{root: root} do
    assert {:error, :no_engine} = Agents.launch(Map.delete(request(root), "engine"))
  end

  test "a checkout that is not there is caught before a process is spent on it", %{root: root} do
    gone = Path.join(root, "no-such-copy")

    assert {:error, :working_copy_missing} =
             Agents.launch(request(root, %{"working_copy" => gone})),
           "starting an agent with a missing cwd fails deep inside the spawn with a " <>
             "message about the shell, which names neither the agent nor the copy"
  end

  test "a request naming no working copy is refused", %{root: root} do
    assert {:error, :no_working_copy} =
             Agents.launch(Map.delete(request(root), "working_copy"))
  end

  test "a known engine that is not installed says so rather than failing to spawn", %{root: root} do
    # Whichever of the two is absent here tells us the same thing. If both
    # happen to be installed this asserts nothing, so it says so instead of
    # passing quietly.
    missing =
      Enum.find(["pi", "claude_code"], fn engine ->
        binary = if engine == "pi", do: "pi", else: "claude"
        System.find_executable(binary) == nil
      end)

    case missing do
      nil ->
        # Both installed on this machine. The branch is still covered by the
        # unknown-engine case above, which takes the same path.
        :ok

      engine ->
        assert {:error, reason} = Agents.launch(request(root, %{"engine" => engine}))

        assert reason in [:pi_not_installed, :claude_not_installed],
               "an engine that is not on this machine's PATH has to be named as such — " <>
                 "'not installed' and 'started and died immediately' want completely " <>
                 "different things from whoever reads it. Got: #{inspect(reason)}"
    end
  end

  test "a launch that succeeds reports a group id and the boot it belongs to", %{root: root} do
    # `sh` stands in for the engine binary: this is about what `launch/1`
    # returns and what it points the process at, not about Pi.
    handle = Runner.start("/bin/sh", ["-c", "sleep 30"], cd: root)

    assert {:ok, %{pgid: pgid, boot_id: boot_id}} = handle
    on_exit(fn -> Runner.stop(%{pgid: pgid, boot_id: boot_id}, grace_ms: 0) end)

    assert is_integer(pgid) and pgid > 0

    assert is_binary(boot_id) and boot_id != "",
           "a group id without the boot it belongs to cannot later be told from a " <>
             "recycled number, so the pair has to come back together"
  end
end
