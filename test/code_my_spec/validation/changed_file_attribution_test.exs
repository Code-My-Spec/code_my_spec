defmodule CodeMySpec.Validation.ChangedFileAttributionTest do
  @moduledoc """
  Which files a stop is allowed to block on.

  The changed-file set starts from mtime, and mtime cannot tell "the agent
  wrote this" from "git wrote this". `git rebase` and `git checkout` touch every
  file they move, so a session that rebases onto a busy main inherits the whole
  rebase as its own work. The window is the task's `started_at`, so a task
  blocked upstream for days collects more of the repo the longer it waits.

  That is survivable only because PostToolUse records what the agent actually
  wrote. The bug was what happened when that record came back empty: the filter
  returned *every* mtime-dirty file rather than none, so the one mechanism that
  narrows the set removed itself instead. A stop then blocked five times running
  on 49 credo violations in spex belonging to three other stories — a gate whose
  only compliant response is to edit code the agent does not own.

  Issue 08cc680f. These cover the property directly: mtime moves, git state does
  not, and the blocking set follows the attribution rather than the clock.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Validation

  setup do
    scope = full_scope_fixture()
    %{scope: scope, session_id: "attr-#{System.unique_integer([:positive])}"}
  end

  defp file!(scope, path, mtime) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :implementation,
      valid: true,
      mtime: mtime
    })
  end

  # The rebase, reproduced without one: rows whose mtime moved but which this
  # session never wrote.
  defp rebase_touched(scope, count) do
    now = DateTime.utc_now()

    for i <- 1..count do
      file!(scope, "test/spex/other_story_#{i}_spex.exs", now)
    end
  end

  describe "a session that recorded no edits" do
    # Rebase-sized, deliberately. Below the threshold the mtime set is kept —
    # see `@rebase_sized` and the test at the end of this file for why.
    test "does not adopt a rebase-sized mtime set", %{scope: scope, session_id: session_id} do
      rebase_touched(scope, 60)

      changed = changed_files(scope, session_id)

      assert changed == [],
             "a session with no recorded edits wrote nothing; adopting the rebase is " <>
               "what blocked a stop on 49 violations in other stories' spex"
    end

    test "says so, because empty attribution has two very different causes", %{
      scope: scope,
      session_id: session_id
    } do
      rebase_touched(scope, 60)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          changed_files(scope, session_id)
        end)

      assert log =~ "recorded no edits",
             "an agent that wrote nothing and an attribution pipeline that is broken " <>
               "produce the same empty set, and only the log separates them"
    end

    # The case that fail-closed got wrong, and it is not hypothetical: this is
    # what broke 983's criterion 8163 (issue 90311b6b).
    #
    # A spex writes a file and drives the stop hook with a session_id, and spex
    # do not fire PostToolUse — so attribution is legitimately empty while the
    # turn genuinely changed something. Discarding that set left the real
    # finding unblocked and a different problem answering in its place, which
    # reads as the wrong rule rather than a missing file list.
    #
    # Anything under `@rebase_sized` is kept for that reason. The size is the
    # only signal available here, and a turn's worth of edits is not a rebase.
    test "keeps a turn-sized set written outside Write/Edit", %{
      scope: scope,
      session_id: session_id
    } do
      file!(scope, "test/spex/983_x/criterion_1_spex.exs", DateTime.utc_now())

      assert [%{path: "test/spex/983_x/criterion_1_spex.exs"}] =
               changed_files(scope, session_id),
             "a spex writes without PostToolUse, so empty attribution here means " <>
               "'wrote through another path', not 'wrote nothing'"
    end

    # A quiet turn is the common case and must not be noisy.
    test "is silent when nothing looks changed either", %{scope: scope, session_id: session_id} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          changed_files(scope, session_id)
        end)

      refute log =~ "recorded no edits"
    end
  end

  describe "a session that recorded edits" do
    test "keeps only what it wrote", %{scope: scope, session_id: session_id} do
      rebase_touched(scope, 8)
      file!(scope, "lib/my_app/accounts.ex", DateTime.utc_now())

      FileEdits.track_edit(session_id, "lib/my_app/accounts.ex")

      assert [%{path: "lib/my_app/accounts.ex"}] = changed_files(scope, session_id)
    end

    # The reported failure in miniature: the agent's own edits are a rounding
    # error next to what the rebase touched.
    test "is not widened by the rebase around it", %{scope: scope, session_id: session_id} do
      rebase_touched(scope, 200)

      for path <- ["lib/a.ex", "lib/b.ex", "lib/c.ex"] do
        file!(scope, path, DateTime.utc_now())
        FileEdits.track_edit(session_id, path)
      end

      changed = changed_files(scope, session_id) |> Enum.map(& &1.path) |> Enum.sort()

      assert changed == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end
  end

  # No session at all is a direct caller rather than an agent turn — an
  # evaluator that never goes through Write/Edit. Those keep mtime semantics,
  # which is the distinction the fix turns on: "no session" and "a session that
  # recorded nothing" are not the same answer.
  test "a caller with no session keeps the mtime view", %{scope: scope} do
    rebase_touched(scope, 5)

    assert length(changed_files(scope, nil)) == 5
  end

  defp changed_files(scope, session_id) do
    Validation.changed_files_for_task(
      scope,
      %{started_at: DateTime.add(DateTime.utc_now(), -3600, :second)},
      session_opts(session_id)
    )
  end

  defp session_opts(nil), do: []
  defp session_opts(session_id), do: [session_id: session_id]
end
