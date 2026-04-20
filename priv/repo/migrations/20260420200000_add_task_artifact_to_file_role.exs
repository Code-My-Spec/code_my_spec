defmodule CodeMySpec.Repo.Migrations.AddTaskArtifactToFileRole do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'task_artifact'"
  end

  def down do
    :ok
  end
end
