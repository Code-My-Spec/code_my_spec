defmodule CmsHarness.AFailedStartSaysSoOnTheHarnessTest do
  @moduledoc """
  A start that fails is recorded where the failure happened.

  Issue `68e535fd`. `Engine.start/1`'s `{:error, reason}` branch logged nothing,
  so a failed start left no trace in `harness.log` — the only record was the
  server's line, which carries the reason as a string and nothing about which
  machine or which checkout produced it.

  Reconstructing one episode, the whole harness-side record was a single
  `terminate/2` line. The reason named `Anubis.Client`, and with nothing else to
  go on that module name was the only clue to which supervisor had raised it.
  The inference drawn from it was wrong twice: once about the root cause, once
  about whether the harness was even running the fix.

  Asserted on the message rather than by forcing a supervisor failure:
  `@supervisor` is a compile-time attribute with no seam, and what can regress
  here is what the line says, not that `Logger.warning/1` works.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine

  @agent "83bf9c09-6303-4b76-b565-b3e0a2e9adb7"
  @copy "/Users/someone/code_my_spec/.claude/worktrees/verify"

  test "it names the agent and the checkout" do
    line = Engine.describe_start_failure(@agent, @copy, :whatever)

    assert line =~ @agent, """
    A harness serves fifteen checkouts. Without the agent id this line cannot be
    matched to the server's line for the same event, which is the join that
    makes either of them useful.
    """

    assert line =~ @copy
  end

  test "and carries the reason, not a summary of it" do
    reason = {:shutdown, {:failed_to_start_child, Anubis.Client, {:already_started, self()}}}

    line = Engine.describe_start_failure(@agent, @copy, reason)

    assert line =~ "failed_to_start_child",
           "the shape is the diagnosis — a reason flattened to a word is what left " <>
             "the module name as the only clue"

    assert line =~ "already_started"
  end

  # `inspect/2` with no bound will render an agent's whole option list, and one
  # of those carries a credential.
  test "a large reason does not run away with the log" do
    reason = {:shutdown, Enum.map(1..500, &{:"key#{&1}", String.duplicate("x", 100)})}

    line = Engine.describe_start_failure(@agent, @copy, reason)

    assert String.length(line) < 1_000,
           "one failed start would push everything around it out of a reader's window"
  end
end
