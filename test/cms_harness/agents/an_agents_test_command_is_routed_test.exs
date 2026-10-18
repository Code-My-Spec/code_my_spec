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

  # 24f3668c: a second occurrence (c2fb6839) reported no run id came back at
  # all after a client timeout, so the agent could not even name which run to
  # ask about. `get_analysis_output`'s `source` selector needs no id -- this
  # is the message naming that route.
  test "a timed-out run names get_analysis_output's source selector, not just a run id" do
    message = Bash.timed_out("wc-1")

    assert message =~ "get_analysis_output"
    assert message =~ "no run id required"
    assert message =~ "exunit for mix test"
    assert message =~ "/api/harnesses/wc-1/analysis/wait"
  end
end
