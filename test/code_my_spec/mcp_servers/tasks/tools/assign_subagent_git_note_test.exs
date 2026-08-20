defmodule CodeMySpec.McpServers.Tasks.Tools.AssignSubagentGitNoteTest do
  @moduledoc """
  The assignment reply says a sub-agent cannot commit.

  `PreToolUse` denies every mutating git subcommand to a sub-agent — b5e305fc,
  where a wandering QA sub-agent ran `git revert` under the engineer's identity
  and silently destroyed a fix. That guard is right and is not what this is
  about.

  What the guard cannot reach is the agent writing the assignment. 461ff38b: a
  fix-* sub-agent was handed a prompt carrying detailed commit-and-push
  instructions across three repos and a whole "Git safety" section, did the
  work, verified it — compiles, tests, a manual smoke test against a running
  server — and discovered at the first `git add` that none of it was
  followable. It handed the diffs back and reported the assignment incomplete.
  The assigning agent had no way to know it was writing impossible steps,
  because the restriction only ever announced itself in a refusal the assigner
  never sees.

  So it is said at assignment time, which is the only moment it is actionable:
  before the prompt is written.

  The wording is pinned here; the wiring — that `execute/2` actually appends it
  — is covered by story 704's spex, which run this tool for real.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Tasks.Tools.AssignSubagent

  test "it tells the assigner not to write commit steps into the prompt" do
    note = AssignSubagent.git_note()

    assert note =~ "cannot commit"

    for step <- ~w(commit push rebase stash) do
      assert note =~ step,
             "the assigner needs the whole shape of what will be refused, not one " <>
               "example — 461ff38b's prompt carried a Git safety section, not a " <>
               "single command"
    end
  end

  test "it names the handoff, not just the restriction" do
    note = AssignSubagent.git_note()

    assert note =~ "file edits",
           "naming the restriction without naming the handoff leaves the assigner to " <>
             "invent one, which is the second thing 461ff38b asked for"

    assert note =~ "committing stays with you",
           "and says whose job it now is, so the work does not simply stall"
  end
end
