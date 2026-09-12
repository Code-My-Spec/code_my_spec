defmodule CodeMySpec.Repo.Migrations.DropTheOrphanedToolsSeenAt do
  @moduledoc """
  Removes `working_copies.tools_seen_at`, which nothing reads and whose original
  remover can never run again.

  How it survived, because the sequence is the interesting part and it will
  recur otherwise:

  Two migrations were stamped `20260912010000` —
  `a_restart_remembers_what_it_was_for`, which creates `agent_restarts` and adds
  this column, and `a_resolved_question_keeps_its_answer`, which adds
  `questions.resolution`. Ecto keys `schema_migrations` by version integer, so
  only one row can record that version and whichever file lost was skipped
  permanently.

  The repair renamed the second to `20260912040000`, which was correct. But by
  then `20260912020000` — the migration that DROPS this column — had already
  been recorded as applied. So when the restart migration finally ran it added
  the column back, and its remover was already spent.

  End state: the column exists, nothing in `lib/` references it, and no existing
  migration will ever take it away. Hence this one.

  `IF EXISTS` because the three databases disagree about whether it is there at
  all, for exactly the reasons above — the dev database has it, a database built
  from a clean history never did, and one built mid-repair could go either way.
  Asserting which would be guessing about a state this migration exists to stop
  people guessing about.
  """

  use Ecto.Migration

  def change do
    execute "ALTER TABLE working_copies DROP COLUMN IF EXISTS tools_seen_at",
            "ALTER TABLE working_copies ADD COLUMN IF NOT EXISTS tools_seen_at timestamp"
  end
end
