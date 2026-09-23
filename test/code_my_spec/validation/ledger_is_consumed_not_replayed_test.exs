defmodule CodeMySpec.Validation.LedgerIsConsumedNotReplayedTest do
  @moduledoc """
  d726cfda — a continuous session that has ever written a file could never
  pass the stop hook again.

  `remote_changed_files/3`'s no-task branch reads every path
  `FileEdits.get_edited_files/1` has ever recorded for a session, with no
  window. Every one of those that still resolves to a File row makes
  `changed_files` non-empty, which makes `Analysis.needs_run?/5` enqueue
  compiler + credo unconditionally on every single stop, forever — measured
  at 314 rows over 16 days on one session. The fix is not a window (an
  external session has no `started_at` to window against, unlike a task) but
  consumption: once a stop has read the ledger and acted on it, the paths it
  read are forgotten, so the next stop with nothing new written sees an empty
  ledger and reads as the quiet stop the function's own comment already
  promised.

  Exercised through `remote_changed_files_for_test/3` directly rather than
  the full `validate_stop/2` dispatch — the livelock lives entirely in this
  one function's relationship with the ledger, and a full stop needs a
  reachable `Analysis.remote_executor/1`, which is a different thing to fix
  than this.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Validation

  @session "ledger-consumption-session"

  setup do
    scope = %{full_scope_fixture() | cwd: nil}

    {1, _rows} =
      Files.upsert_files(scope, [
        %{path: "lib/mine.ex", role: :implementation, fingerprint: "a", valid: true}
      ])

    %{scope: scope}
  end

  defp read(scope), do: Validation.remote_changed_files_for_test(scope, nil, session_id: @session)

  test "the same edit does not keep reporting changed after a stop has read it", %{scope: scope} do
    :ok = FileEdits.track_edit(@session, "lib/mine.ex")

    {first_files, consume} = read(scope)
    assert Enum.map(first_files, & &1.path) == ["lib/mine.ex"]

    # The step the bug skipped entirely.
    consume.()

    {second_files, _consume} = read(scope)

    assert second_files == [],
           "an unconsumed ledger is exactly d726cfda: the same edit, read once and acted " <>
             "on, was still there on every later stop with nothing new written"
  end

  test "a real write between two stops is still reported after the first is consumed", %{
    scope: scope
  } do
    {1, _} =
      Files.upsert_files(scope, [
        %{path: "lib/theirs.ex", role: :implementation, fingerprint: "b", valid: true}
      ])

    :ok = FileEdits.track_edit(@session, "lib/mine.ex")
    {_files, consume} = read(scope)
    consume.()

    :ok = FileEdits.track_edit(@session, "lib/theirs.ex")
    {files, _consume} = read(scope)

    assert Enum.map(files, & &1.path) == ["lib/theirs.ex"],
           "consuming must not make the ledger blind to what comes after it"
  end

  test "consuming is a no-op until the caller actually calls it" do
    scope = %{full_scope_fixture() | cwd: nil}

    {1, _} =
      Files.upsert_files(scope, [
        %{path: "lib/mine.ex", role: :implementation, fingerprint: "a", valid: true}
      ])

    session = "unconsumed-#{System.unique_integer([:positive])}"
    :ok = FileEdits.track_edit(session, "lib/mine.ex")

    {_files, _consume} = Validation.remote_changed_files_for_test(scope, nil, session_id: session)

    assert FileEdits.get_edited_files(session) == ["lib/mine.ex"],
           "the read alone must not clear anything — only calling the returned " <>
             "function may, and this stop never called it"
  end

  test "a session with no recorded edits reads as quiet, before and after" do
    scope = %{full_scope_fixture() | cwd: nil}
    session = "quiet-#{System.unique_integer([:positive])}"

    {files, consume} = Validation.remote_changed_files_for_test(scope, nil, session_id: session)
    assert files == []

    consume.()

    {files, _consume} = Validation.remote_changed_files_for_test(scope, nil, session_id: session)
    assert files == []
  end
end
