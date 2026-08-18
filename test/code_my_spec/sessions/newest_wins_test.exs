defmodule CodeMySpec.Sessions.NewestWinsTest do
  @moduledoc """
  Which conversation a working copy is in, when two sessions start at once.

  `external_id_for_harness/1` is the join between a harness and a conversation —
  the only route from "which working copy" to "which session" for a recorded
  model turn, a question raised by `ask_user`, or a listing from
  `list_user_questions`. It resolves newest-first and takes one:

      order_by([s], desc: s.inserted_at) |> limit(1)

  With second-granularity timestamps two sessions started inside one second had
  identical sort keys, so the answer was whatever the planner yielded. Work then
  lands in the wrong conversation: story 896's criterion 2418 saw a list scoped
  to the second session return the first session's question too, because both
  asks had resolved to the same row (`a879ed53`).

  The fix is the schema, not the migration, and that is worth recording. The
  Postgres column was `timestamp` — precision 6 — all along; it is Ecto's
  `:utc_datetime` that truncates to seconds on the way in. Widening the column
  changed nothing on its own. `timestamps(type: :utc_datetime_usec)` on
  `Sessions.Session` is what actually stopped the collision.

  Which is why this test creates sessions back to back rather than asserting on
  a column type: the type was never the thing that was wrong.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Sessions

  defp start_session(scope, external_id) do
    {:ok, session} = Sessions.find_or_create_session(scope, external_id)
    session
  end

  test "two sessions started back to back are distinguishable" do
    scope = full_scope_fixture()

    first = start_session(scope, "back-to-back-first")
    second = start_session(scope, "back-to-back-second")

    refute DateTime.compare(first.inserted_at, second.inserted_at) == :eq,
           """
           Both sessions carry the same insertion time, so `desc: :inserted_at`
           has no defined answer and the harness resolves to whichever row comes
           back first. That is how a question asked in one conversation was
           filed under another.

           first:  #{inspect(first.inserted_at)}
           second: #{inspect(second.inserted_at)}
           """
  end

  test "the harness resolves to the session that started last" do
    scope = full_scope_fixture()

    _first = start_session(scope, "resolves-first")
    second = start_session(scope, "resolves-second")

    assert Sessions.external_id_for_harness(scope.active_harness_id) == second.external_conversation_id,
           "newest wins is the documented rule; with a tie it was undefined"
  end

  test "microsecond precision survives the round trip" do
    scope = full_scope_fixture()
    session = start_session(scope, "precision-check")

    reloaded = Sessions.get_session(scope, session.id)

    assert reloaded.inserted_at.microsecond |> elem(1) > 0,
           """
           The timestamp came back with zero declared precision, which means it
           was stored truncated. The Postgres column has precision 6 and always
           did — this is `Sessions.Session`'s own `timestamps/1` type, and it is
           the thing that actually decides.
           """
  end
end
