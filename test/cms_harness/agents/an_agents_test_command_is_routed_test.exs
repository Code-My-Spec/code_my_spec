defmodule CmsHarness.Agents.AnAgentsTestCommandIsRoutedTest do
  @moduledoc """
  An in-app agent's `mix test` goes through its copy's analysis service, the
  way a Claude Code agent's does through the PreToolUse hook (capture D).
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Tools.Bash

  test "the test segment is routed to its copy's harness, the rest kept" do
    assert {:routed, command, "mix test"} =
             Bash.routed("mix test test/a_test.exs 2>&1 | tail -5", "/w/copy", "wc-1")

    assert command =~ "/api/harnesses/wc-1/analysis/run"
    assert String.ends_with?(command, " 2>&1 | tail -5")
  end

  test "anything else is left alone" do
    assert :pass = Bash.routed("ls -la", "/w/copy", "wc-1")
  end

  test "an agent with no copy is left alone" do
    assert :pass = Bash.routed("mix test", "/w/copy", nil)
  end
end
