defmodule CodeMySpec.Repo.Migrations.AddArchitectureToProjectConfigurations do
  use Ecto.Migration

  # No default here. Defaults live on the schema, so one place decides what a
  # new configuration means and a column default cannot drift from it.
  def change do
    alter table(:project_configurations) do
      add :architecture, :string
    end
  end
end
