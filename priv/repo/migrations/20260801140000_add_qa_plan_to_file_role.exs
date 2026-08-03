defmodule CodeMySpec.Repo.Migrations.AddQaPlanToFileRole do
  @moduledoc """
  The QA plan and journey plan become synced files.

  `qa_setup` and the journey requirements gated on reading
  `.code_my_spec/qa/plan.md` off disk. The classifier had no clause for it, so it
  never synced, and on a server with no working copy the checker reported it
  missing while it sat in the agent's directory. Two drills ended there.

  SQLite stores `role` as a plain string, so there is no CLI counterpart.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: execute("ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'qa_plan'")
  def down, do: :ok
end
