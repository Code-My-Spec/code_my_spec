defmodule CodeMySpec.Repo.Migrations.AddSetupRolesToFileRole do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'mix_exs'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'credo_exs'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'claude_md'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'setup_config'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'test_support'"
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'agents_md'"
  end

  def down do
    :ok
  end
end
