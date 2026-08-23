defmodule CodeMySpec.Hooks.SessionStartCoOccupancyTest do
  @moduledoc """
  Two agents in one worktree get told so, at the moment it becomes true.

  `1f94a769`. A worktree is one index and one HEAD, so two sessions in it are
  two agents on one staging area. In a single morning that produced a
  `git add -- <path> && git commit` that swept up eight files the other session
  had staged and pushed them under a message about one test file; a `git push`
  that shipped a commit the pusher had never made and reported it verified; a
  rebase that moved HEAD under a live session; and autostash entries appearing
  and vanishing in the other session's tree.

  Nothing reported any of it. `git status` and `git log` look normal, and both
  sessions commit as the same author — only the `Claude-Session` trailer tells
  the commits apart. So the first symptom is a commit containing files you
  never touched, which reads as your own mistake.

  A warning rather than a refusal, deliberately: two sessions in one worktree
  is sometimes intended, and locking the second out would be a worse failure
  than the one prevented. What this buys is that the first symptom is a
  sentence at session start instead of a mislabelled commit hours later.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Hooks.SessionStart

  setup do
    %{scope: full_scope_fixture()}
  end

  defp start_session(scope, external_id) do
    SessionStart.handle(scope, %{"session_id" => external_id})
  end

  test "the first session in a checkout is not warned", %{scope: scope} do
    {200, body} = start_session(scope, "session-alone")

    refute Map.has_key?(body, :systemMessage)
  end

  test "a second session on the same harness is told about the first", %{scope: scope} do
    {200, _} = start_session(scope, "session-first")
    {200, body} = start_session(scope, "session-second")

    assert body.systemMessage =~ "session-first"
    assert body.systemMessage =~ "one index and one HEAD"

    assert body.systemMessage =~ "git diff --cached",
           "the advice has to be actionable — the failure is a commit carrying " <>
             "files the other session staged, and checking the staged set is what " <>
             "catches it"
  end

  test "re-entering the same session is not a co-occupant", %{scope: scope} do
    {200, _} = start_session(scope, "session-same")
    {200, body} = start_session(scope, "session-same")

    refute Map.has_key?(body, :systemMessage)
  end

  # The other checkout is a different hazard, not a lesser one, and it takes
  # different advice: no shared index, but shared task records. That is the case
  # `Sessions.concurrent_sessions/2` was written for — a second agent using the
  # only session id it could find, which was the first agent's.
  test "a session on another checkout warns about tasks, not about git", %{scope: scope} do
    {200, _} = start_session(scope, "session-here")

    {:ok, other} = WorkingCopies.issue(scope, nil, label: "another checkout")
    elsewhere = %{scope | active_working_copy_id: other.id}

    {200, body} = start_session(elsewhere, "session-elsewhere")

    assert body.systemMessage =~ "different checkout"
    assert body.systemMessage =~ "task records are shared"

    refute body.systemMessage =~ "one index and one HEAD",
           "there is no shared staging area here, and telling an agent not to " <>
             "rebase because of a session in another worktree is advice it cannot " <>
             "use and will learn to ignore"
  end

  # Both at once is the real state of this machine on a busy evening, and each
  # session needs the warning that applies to it.
  test "both hazards are reported when both are present", %{scope: scope} do
    {200, _} = start_session(scope, "session-same-copy")

    {:ok, other} = WorkingCopies.issue(scope, nil, label: "another checkout")
    {200, _} = start_session(%{scope | active_working_copy_id: other.id}, "session-other-copy")

    {200, body} = start_session(scope, "session-third")

    assert body.systemMessage =~ "same checkout"
    assert body.systemMessage =~ "session-same-copy"
    assert body.systemMessage =~ "different checkout"
    assert body.systemMessage =~ "session-other-copy"
  end
end
