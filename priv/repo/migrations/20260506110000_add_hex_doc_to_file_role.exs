defmodule CodeMySpec.Repo.Migrations.AddHexDocToFileRole do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'hex_doc'"
  end

  def down do
    :ok
  end
end
