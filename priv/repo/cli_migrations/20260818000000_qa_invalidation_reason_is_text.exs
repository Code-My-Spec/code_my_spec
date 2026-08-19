defmodule CodeMySpec.Repo.Migrations.QaInvalidationReasonIsText do
  @moduledoc """
  Widen `qa_invalidations.reason` from varchar(255) to text.

  `:string` in a migration is `varchar(255)`, and the reason is prose: the tool
  asks for one ("the reason is what shows up in the QA history for the next
  engineer to understand why the prior pass was rejected"), the validation
  requires it to be non-empty, and anybody writing a useful one runs past 255
  characters without noticing there is a limit.

  What made this worth a migration rather than a shrug is how it failed.
  Postgres raised `:string_data_right_truncation`, which reached the agent as

      MCP error -32603: Internal error

  and nothing else. Two agents hit it — one retried three times and filed a
  framework issue concluding it was not transient, which was correct and as far
  as the surface let them get. The sentence naming the cause existed only in
  `web.log`, on the server, where neither could see it.

  Text rather than a longer varchar: there is no length at which a human
  explanation is definitively finished, and picking one only moves where this
  happens again.

  Nothing to backfill. Existing rows are valid text.

  ## Why this is a no-op here and not in the Postgres migration it mirrors

  `varchar(255)` is the thing being widened, and SQLite has no such limit to
  widen: every `TEXT`-affinity column already stores a string of any length
  regardless of the type name in its `CREATE TABLE`, and `null: false` was
  already set when this column was created (`20260517152000`). `modify/3`
  changing a column's type is also not something `ecto_sqlite3` can do at
  all — it raises `ArgumentError, "ALTER COLUMN not supported by SQLite3"`,
  which crashed every CLI migration behind it. The Postgres fix is real; on
  SQLite there was nothing to fix.
  """
  use Ecto.Migration

  def up, do: :ok

  def down, do: :ok
end
