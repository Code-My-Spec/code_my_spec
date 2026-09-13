defmodule CodeMySpec.Hooks.SubagentGitAccessTest do
  @moduledoc """
  What a subagent may do with git, and why the line moved.

  `b5e305fc`: a QA subagent ran `git revert` under the engineer's git identity
  and silently destroyed a fix. The response was "no git for subagents at all",
  which was the tightest safe default available at the time.

  `66f3b098`: that turned out to be a livelock. When the stop hook cannot
  attribute findings it tells the agent to "check `git log -1 -- <path>` before
  repairing anything you do not recognise" — and this hook denied exactly that.
  The harness named the one diagnostic that would clear the block and refused it
  in the same breath. The agent could not attribute, could not honestly clear
  (the findings were real, from another area), could not fix (out of scope), and
  therefore could not stop.

  The danger in b5e305fc is mutation, so the allowlist is by subcommand. These
  assert both halves: history is readable, and nothing that writes gets through
  — including when a write is chained behind a read, which is how an allowlist
  of this shape usually leaks.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Hooks.PreToolUse

  @subagent "agent_01ABC"

  defp decide(command, agent_id) do
    PreToolUse.decide(
      nil,
      %{
        "tool_name" => "Bash",
        "tool_input" => %{"command" => command},
        "agent_id" => agent_id
      },
      1,
      :harness
    )
  end

  defp denied?(response) do
    get_in(response, ["hookSpecificOutput", "permissionDecision"]) == "deny"
  end

  describe "a subagent reading history" do
    test "may run the command the stop hook tells it to run" do
      refute denied?(decide("git log -1 -- lib/code_my_spec/accounts.ex", @subagent))
    end

    test "may run the other read-only subcommands" do
      for command <- [
            "git show HEAD",
            "git diff HEAD~1",
            "git status",
            "git blame lib/a.ex",
            "git rev-parse HEAD"
          ] do
        refute denied?(decide(command, @subagent)), "expected #{command} to be allowed"
      end
    end

    test "may point git at another worktree to read it" do
      refute denied?(decide("git -C ../other log -1", @subagent))
    end

    test "is not confused by git's global options" do
      refute denied?(decide("git --no-pager log --oneline -5", @subagent))
    end
  end

  describe "a subagent writing" do
    # The command from b5e305fc. This is the case the whole denial exists for.
    test "may not revert" do
      assert denied?(decide("git revert abc1234", @subagent))
    end

    test "may not commit, push, reset, or checkout" do
      for command <- [
            "git commit -m wip",
            "git push origin main",
            "git reset --hard HEAD~1",
            "git checkout main",
            "git stash"
          ] do
        assert denied?(decide(command, @subagent)), "expected #{command} to be denied"
      end
    end

    # An allowlist that checks only the first invocation is not an allowlist.
    # `git log && git push` contains a read-only call and is still a push.
    test "may not hide a write behind a read" do
      assert denied?(decide("git log -1 && git push origin main", @subagent))
      assert denied?(decide("git status; git reset --hard", @subagent))
      assert denied?(decide("echo hi | git commit -F -", @subagent))
    end

    # Denying what it cannot parse, rather than passing it. A bare `git` is
    # harmless, but "the allowlist did not recognise this" must not mean "allow".
    test "may not run a git invocation this cannot read" do
      assert denied?(decide("git", @subagent))
    end
  end

  describe "the main agent" do
    test "keeps full git access" do
      refute denied?(decide("git push origin main", nil))
      refute denied?(decide("git revert abc1234", ""))
    end
  end

  describe "commands that are not git" do
    test "pass through untouched" do
      refute denied?(decide("ls -la", @subagent))
    end

    # `git` inside a word is not a git invocation. `digital`, `legit`, a path
    # like `lib/gitlab.ex` — the separator class is what keeps these out.
    test "a word merely containing git is not a git invocation" do
      refute denied?(decide("echo legitimate", @subagent))
      refute denied?(decide("cat lib/gitlab_client.ex", @subagent))
    end
  end
end
