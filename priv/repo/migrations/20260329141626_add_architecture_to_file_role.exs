defmodule CodeMySpec.Repo.Migrations.AddArchitectureToFileRole do
  use Ecto.Migration

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'architecture'"
  end

  def down do
    # Postgres doesn't support removing enum values
    :ok
  end
end
