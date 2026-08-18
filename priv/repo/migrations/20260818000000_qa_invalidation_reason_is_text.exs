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
  """
  use Ecto.Migration

  def up do
    alter table(:qa_invalidations) do
      modify :reason, :text, null: false
    end
  end

  def down do
    # Truncating on the way back rather than failing: a reason that no longer
    # fits is still better recorded short than blocking a rollback.
    execute("UPDATE qa_invalidations SET reason = left(reason, 255)")

    alter table(:qa_invalidations) do
      modify :reason, :string, null: false
    end
  end
end
