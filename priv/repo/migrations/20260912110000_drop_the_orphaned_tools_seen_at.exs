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

  ## Renumbered from 20260912070000, which it collided with

  It was written as `20260912070000` and so was
  `a_requirement_remembers_what_it_was_computed_from`, on another branch, the
  same day. Two files, one version — the identical defect this file's own
  history is about, committed by the fix for it.

  They met at a merge. `Ecto.Migrator` does not refuse the pair; one runs, the
  other is skipped for good, and nothing says which. That is how
  `AddTheRequirementFingerprintColumnWhereItNeverLanded` came to exist: its
  moduledoc reports `code_my_spec_dev` carrying version 20260912070000 with no
  `requirements.inputs_fingerprint`, and reasons that "the version row committed
  and the DDL did not".

  **That diagnosis is wrong, and worth correcting here because the right one is
  the whole argument for this renumber.** The DDL that ran under 20260912070000
  was *this file's* — dropping `tools_seen_at`. The fingerprint migration never
  ran at all, because its version was already taken.

  Renumbered rather than the other one because this is idempotent: `DROP COLUMN
  IF EXISTS` is a no-op on a database that has already had it under the old
  version, and correct on one that never did. The fingerprint migration is
  `alter table/add`, which is not.
  """

  use Ecto.Migration

  def change do
    execute "ALTER TABLE working_copies DROP COLUMN IF EXISTS tools_seen_at",
            "ALTER TABLE working_copies ADD COLUMN IF NOT EXISTS tools_seen_at timestamp"
  end
end
