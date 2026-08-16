defmodule CodeMySpec.Repo.Migrations.AddQaScriptToFileRole do
  @moduledoc """
  The verify scripts integration specs point at become synced files.

  `41406ceb` was filed because a check reading a file the scanner drops is
  invisible to the graph fingerprint, so a published graph gets served as
  current when it is not. Classifying the integration *specs* closed that for
  their contents — and left it open one indirection along.

  `QaIntegrationPlan.check_one_verify_script/2` parses a path out of each spec
  (`.code_my_spec/qa/scripts/verify_github.sh` and its siblings) and asserts
  that file exists. Nothing claimed those paths: `classify_qa/1` matched plans,
  briefs and results, and `Paths.qa_scripts_dir/0` was referenced by no code at
  all. So an agent creating the very script that satisfies the check left
  `files_digest/1` unchanged.

  Matched by directory prefix rather than extension. The specs name the script
  by path and nothing constrains it to `.sh`; the three that exist happen to be
  shell, and a Python one would be equally valid and equally invisible.

  SQLite stores `role` as a plain string, so there is no CLI counterpart —
  same as `add_qa_plan_to_file_role`.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: execute("ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'qa_script'")
  def down, do: :ok
end
