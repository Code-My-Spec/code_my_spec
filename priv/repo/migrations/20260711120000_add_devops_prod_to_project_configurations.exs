defmodule CodeMySpec.Repo.Migrations.AddDevopsProdToProjectConfigurations do
  use Ecto.Migration

  def change do
    alter table(:project_configurations) do
      # Default lives on the schema, never the migration.
      add :devops_prod, :string
    end
  end
end
