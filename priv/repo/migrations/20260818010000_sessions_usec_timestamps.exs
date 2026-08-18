defmodule CodeMySpec.Repo.Migrations.SessionsUsecTimestamps do
  @moduledoc """
  Give `sessions` microsecond timestamps, so "newest wins" means something.

  `Sessions.external_id_for_harness/1` is the join between a harness and a
  conversation — the only way a recorded model turn, a question raised by
  `ask_user`, or a listing from `list_user_questions` gets from "which working
  copy" to "which conversation". It resolves by:

      order_by([s], desc: s.inserted_at) |> limit(1)

  With `timestamps(type: :utc_datetime)` that column is second-granularity, so
  two sessions started inside the same second have identical sort keys and the
  answer is whatever the planner happens to yield first. Not rare in practice:
  an agent restarting quickly, a subagent starting beside its parent, or a
  sprite reconnecting all produce two sessions on one harness within a second.

  When it ties, work lands in the wrong conversation. Story 896's criterion 2418
  found it — two sessions, two questions, and a list scoped to the second
  session returned both, because both asks had resolved to the same row
  (`a879ed53`). That spec carries a `Process.sleep(1_100)` purely to force the
  timestamps apart; it should be deleted with this.

  `:utc_datetime_usec` rather than a tiebreak column: the ordering is already
  the right idea and only its resolution was wrong. Adding a sequence or
  ordering by id would work around a clock that simply was not precise enough,
  and every other table that cares about ordering here already uses usec.

  Existing values widen without loss — a second-precision timestamp is a valid
  microsecond one — so there is nothing to backfill and nothing to reconcile.
  49 rows in dev at the time of writing.

  Shaped after `20260517150000_qa_attempts_usec_timestamps`, which widened the
  same way and for the same reason: ordering that relied on `inserted_at` could
  not disambiguate rapid in-process submissions. That one has no `cli_migrations`
  mirror and neither does this — SQLite stores timestamps as text, so the
  declared type is advisory there and nothing needs rebuilding.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      modify :inserted_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
      modify :updated_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
    end
  end
end
