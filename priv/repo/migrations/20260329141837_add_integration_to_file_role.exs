defmodule CodeMySpec.Repo.Migrations.AddIntegrationToFileRole do
  use Ecto.Migration

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'integration'"
  end

  def down do
    :ok
  end
end
