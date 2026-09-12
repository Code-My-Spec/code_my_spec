defmodule CodeMySpec.Agents.OperatingRulesTest do
  @moduledoc """
  Every agent is told how the machinery works, not only what it is for.

  Each rule covered here was delivered by hand to a running agent on
  2026-09-10, after it had already gone the wrong way. The agent was not being
  careless: it had been told its role and given its tools, and left to infer the
  operating rules from whatever codebase it happened to be standing in.

  These tests pin the rules to the incidents that bought them, so a future edit
  that drops one has to argue with the cost rather than with a preference.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.{OperatingRules, RoleBrief, ToolSets}

  describe "every role carries them" do
    test "all four roles get the rules, not just the one that needed them" do
      for role <- RoleBrief.roles() do
        brief = RoleBrief.for(role)

        assert brief =~ "How this system works",
               "#{role} was left to infer the machinery. Every role runs against the " <>
                 "same harness, and the one that guesses wrong is whichever one " <>
                 "happens to meet it first."
      end
    end

    test "a role we have no brief for is still told nothing" do
      refute RoleBrief.for(:no_such_role)

      refute RoleBrief.for(nil),
             "an agent told something vague about itself is worse off than one told " <>
               "nothing, because it will act on it"
    end
  end

  describe "the rules that were paid for" do
    setup do: %{rules: OperatingRules.text()}

    # A coding agent reported `Unknown tool: promote` twice and stopped rather
    # than improvising. That refusal is what found three separate bugs — the
    # tool registered nowhere, the harness tool list missing it, and an MCP
    # client leak. Every workaround would have hidden one.
    test "a failing tool is reported, not worked around", %{rules: rules} do
      assert rules =~ "report"
      assert rules =~ "Unknown tool"
    end

    # `promote` refused in four seconds and the agent waited twelve minutes,
    # because nothing told it the tool answers before its work is done.
    test "async tools are named as answering immediately", %{rules: rules} do
      assert rules =~ "promote"
      assert rules =~ "start_analysis"
      assert rules =~ "do not poll"
    end

    # Twenty minutes refactoring cyclomatic complexity and nesting depth, none
    # of which gates anything, with one error-severity finding in the way.
    test "only error severity is said to block", %{rules: rules} do
      assert rules =~ "error"
      assert rules =~ "warning"
      assert rules =~ "info"
    end

    # The failure mode that looks most like progress.
    test "changing a rule to clear a gate is refused", %{rules: rules} do
      assert rules =~ "severity"
      assert rules =~ "decoration"
    end

    # Two concurrent `just restart` runs raced on `_build` and deadlocked the
    # machine for eleven minutes; three commits went straight to origin/main
    # from a working copy.
    test "the machinery is not to be driven by hand", %{rules: rules} do
      assert rules =~ "_build"
      assert rules =~ "origin/main"
    end

    # The most expensive hour of the night: `config/dev_cli.exs` written into a
    # game, because that env appears in CodeMySpec's own justfile.
    test "dev_cli is named as the framework's and not a project's", %{rules: rules} do
      assert rules =~ "dev_cli"

      assert rules =~ "wrong environment",
             "the symptom is a missing config file, and an agent that reads that as " <>
               "'create the file' spends an hour doing it"
    end
  end

  # A brief that describes a tool boundary has to describe the real one.
  #
  # The coding brief said "you cannot triage or resolve issues". Coding carries
  # `resolve_issue` and the FixIssues workflow runs on it; what it lacks is
  # `accept_issue` and `dismiss_issue`. A coding agent hit the contradiction
  # head-on and stopped to ask: "My system role says I can't triage or resolve
  # issues, but the FixIssues task's workflow requires calling resolve_issue
  # after each fix. How should I handle that step?" It was right, and there was
  # no answer that did not involve changing something.
  describe "a brief agrees with the tools the role carries" do
    test "coding is not told it cannot resolve issues, because it can" do
      brief = RoleBrief.for(:coding)

      assert "resolve_issue" in ToolSets.for_role(:coding),
             "the premise failed: if coding no longer carries resolve_issue, the " <>
               "brief below should say so and this test should be inverted"

      refute brief =~ "cannot triage or resolve",
             "the brief denies a tool the role is granted, and an agent that " <>
               "believes it stops at the step that needs it"
    end

    test "coding is told which half it does not have" do
      brief = RoleBrief.for(:coding)

      assert brief =~ "accept_issue"
      assert brief =~ "dismiss_issue"
    end
  end

  # It is charged on every turn of every agent, so it has to stay a page.
  test "the rules stay small enough to send every turn" do
    assert byte_size(OperatingRules.text()) < 4_000,
           "operating rules are pasted into every system prompt and paid for on " <>
             "every turn; past a page they stop being rules and become a document " <>
             "nobody reads"
  end
end
