defmodule CodeMySpec.Repo.Migrations.AddKnowledgeRolesToFileRole do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'knowledge'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'project_knowledge'"
  end

  def down do
    :ok
  end
end
