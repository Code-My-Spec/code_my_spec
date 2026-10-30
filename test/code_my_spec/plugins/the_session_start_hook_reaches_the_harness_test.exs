defmodule CodeMySpec.Plugins.TheSessionStartHookReachesTheHarnessTest do
  @moduledoc """
  Issue 945c8a01: Claude Code runs no HTTP hook for SessionStart (or Setup) —
  it skips one with "HTTP hooks are not supported for SessionStart" — so the
  plugin's SessionStart must be a command hook posting to the harness, or no
  terminal session ever registers as an agent (story 1122).
  """
  use ExUnit.Case, async: true

  @hooks Path.expand("../../../plugins/claude/hooks/hooks.json", __DIR__)

  test "the plugin's SessionStart is a command hook that posts the payload to the harness" do
    hooks = @hooks |> File.read!() |> Jason.decode!()

    assert [%{"hooks" => [hook]}] = hooks["hooks"]["SessionStart"]
    assert hook["type"] == "command"

    assert hook["command"] ==
             ~s(python3 "${CLAUDE_PLUGIN_ROOT}/hooks/post-hook.py" session-start)
  end

  test "command hooks post the original payload to the configured port and preserve the response" do
    script = Path.expand("../../support/claude_cloud_ports_test.py", __DIR__)
    {output, status} = System.cmd("python3", ["-B", script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
