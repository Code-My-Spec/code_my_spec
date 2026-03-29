defmodule CodeMySpec.Repo.Migrations.AddIssueToFileRole do
  use Ecto.Migration

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'issue'"
  end

  def down do
    :ok
  end
end
